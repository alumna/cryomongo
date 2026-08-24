require "bson"
require "./message_part"
require "./op_code"

# OP_MSG is an extensible message format designed to subsume the functionality of other opcodes.
struct Mongo::Messages::OpMsg < Mongo::Messages::Part
  @[Field(ignore: true)]
  getter op_code : OpCode = OpCode::Msg

  @[Flags]
  enum Flags : Int32
    ChecksumPresent
    MoreToCome
    ExhaustAllowed  = 1 << 16
  end

  getter flag_bits : Flags
  getter sections : Array(Part)
  getter checksum : UInt32?

  def initialize(@flag_bits : Flags, @sections, @checksum = nil)
  end

  def initialize(body, *, flag_bits : Flags = :none)
    initialize(
      flag_bits: flag_bits,
      sections: [
        Messages::OpMsg::SectionBody.new(BSON.new(body)),
      ].map(&.as(Messages::Part))
    )
  end

  def initialize(io : IO, header : Messages::Header)
    size = header.body_size
    msg_bytes = Messages::BufferPool.checkout(size)
    begin
      Messages.read_exact(io, msg_bytes[0, size])
    rescue error
      Messages::BufferPool.checkin(msg_bytes)
      raise error
    end
    initialize(msg_bytes, header, used: size)
  end

  def initialize(msg_bytes : Bytes, header : Messages::Header, used : Int32 = msg_bytes.size)
    begin
      view_bytes = msg_bytes[0, used]
      msg_view = IO::Memory.new(view_bytes, writable: false)

      @flag_bits = Flags.from_value(msg_view.read_bytes(UInt32, IO::ByteFormat::LittleEndian))
      @sections = typeof(@sections).new

      has_checksum = @flag_bits.checksum_present?
      limit_pos = used - (has_checksum ? 4 : 0)

      while msg_view.pos < limit_pos
        payload_type = msg_view.read_bytes(UInt8, IO::ByteFormat::LittleEndian)

        case payload_type
        when 0_u8
          payload = Messages.read_bson_view(view_bytes, msg_view)
          @sections << SectionBody.new(payload)
        when 1_u8
          marker = msg_view.pos
          sequence_size = msg_view.read_bytes(Int32, IO::ByteFormat::LittleEndian)

          sequence_identifier = msg_view.gets('\0', chomp: true)
          raise Mongo::Error.new("Invalid OP_MSG: EOF while reading sequence identifier") unless sequence_identifier

          contents = Array(BSON).new

          while msg_view.pos - marker < sequence_size
            contents << Messages.read_bson_view(view_bytes, msg_view)
          end

          @sections << SectionDocumentSequence.new(
            payload: SectionDocumentSequence::SectionPayload.new(
              sequence_identifier, contents
            )
          )
        else
          raise Mongo::Error.new "Received invalid payload type: #{payload_type}"
        end
      end

      if has_checksum
        @checksum = msg_view.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
      end
      own_payload
    ensure
      Messages::BufferPool.checkin(msg_bytes)
    end
  end

  # Copy BSON out of the receive buffer so the Channel pool can take it back.
  private def own_payload : Nil
    owned = Array(Part).new(@sections.size)
    @sections.each do |section|
      case section
      when SectionBody
        owned << SectionBody.new(BSON.new(section.payload.data))
      when SectionDocumentSequence
        docs = Array(BSON).new(section.payload.contents.size)
        section.payload.contents.each { |doc| docs << BSON.new(doc.data) }
        owned << SectionDocumentSequence.new(
          payload: SectionDocumentSequence::SectionPayload.new(
            section.payload.sequence_identifier,
            docs
          )
        )
      else
        owned << section
      end
    end
    @sections = owned
  end

  struct SectionBody < Part
    getter payload_type : UInt8 = 0_u8
    getter payload : BSON

    def initialize(@payload : BSON); end
  end

  struct SectionDocumentSequence < Part
    getter payload_type : UInt8 = 1_u8
    getter payload : SectionPayload

    def initialize(@payload : SectionPayload); end

    struct SectionPayload < Part
      getter sequence_size : Int32 = 0
      getter sequence_identifier : String
      getter contents : Array(BSON)

      def initialize(@sequence_identifier, @contents)
        @sequence_size = self.part_size
      end
    end
  end

  def body : BSON
    sections.each do |section|
      return section.payload if section.is_a?(SectionBody)
    end
    raise Mongo::Error.new("Invalid OP_MSG: Missing body section")
  end

  def each_sequence(&)
    sections.each do |section|
      if section.is_a?(SectionDocumentSequence)
        yield section.payload.sequence_identifier, section.payload.contents
      end
    end
  end

  def sequence(key : String, contents : Array(BSON))
    @sections << SectionDocumentSequence.new(
      payload: SectionDocumentSequence::SectionPayload.new(
        sequence_identifier: key,
        contents: contents
      )
    )
  end

  def valid?
    body["ok"] == 1
  end

  def error? : Exception?
    cached_body = body

    err_label_set = labels_from(cached_body["errorLabels"]?)

    if cached_body["ok"] == 1
      topology_version = cached_body["topologyVersion"]?.try(&.as(BSON))
      if errors = cached_body["writeErrors"]?
        Mongo::Error::CommandWrite.new(errors.as(BSON), error_labels: err_label_set, topology_version: topology_version)
      elsif write_error = cached_body["writeConcernError"]?
        wc = write_error.as(BSON)
        labels_from(wc["errorLabels"]?).each { |label| err_label_set << label }
        Mongo::Error::WriteConcern.new(wc, error_labels: err_label_set, topology_version: topology_version)
      end
    else
      err_msg = cached_body["errmsg"]?.try(&.as(String))
      err_code_name = cached_body["codeName"]?.try(&.as(String))
      err_code = cached_body["code"]?
      details = cached_body["errInfo"]?.try(&.as(BSON))
      topology_version = cached_body["topologyVersion"]?.try(&.as(BSON))
      base_backoff_ms = cached_body["baseBackoffMS"]?.try { |v|
        v.as?(Int) ? v.as(Int).to_i64 : nil
      }
      Mongo::Error::Command.new(err_code, err_code_name, err_msg, details, error_labels: err_label_set, topology_version: topology_version, base_backoff_ms: base_backoff_ms, reply: BSON.new(cached_body.data))
    end
  end

  # failCommand may put labels on the reply or inside writeConcernError.
  private def labels_from(value) : Set(String)
    labels = Set(String).new
    if bson = value.as?(BSON)
      bson.each do |_, item|
        labels << item if item.is_a?(String)
      end
    end
    labels
  end

  # APM copy of the command or reply. Must not mutate the live body
  # (`BSON.new(BSON)` is a no-op). Sensitive commands become `{}`.
  def safe_payload(command)
    cached_body = body
    command_name = command.responds_to?(:name) ? command.name : ""
    if Mongo::Monitoring::Redact.sensitive?(command_name, cached_body)
      return Mongo::Monitoring::Redact::EMPTY
    end

    BSON.build do |builder|
      cached_body.each { |key, value, code|
        if value.is_a?(BSON) && code.array?
          builder.append_array(key, value)
        else
          builder[key] = value
        end
      }
      each_sequence do |key, contents|
        builder[key] = contents
      end
    end
  end
end
