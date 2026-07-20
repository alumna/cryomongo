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
    ExhaustAllowed  = 16
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
    msg_bytes = Bytes.new(size)
    io.read_fully(msg_bytes)
    msg_view = IO::Memory.new(msg_bytes, writeable: false)

    @flag_bits = Flags.from_value(msg_view.read_bytes(UInt32, IO::ByteFormat::LittleEndian))
    @sections = typeof(@sections).new

    has_checksum = @flag_bits.checksum_present?
    limit_pos = size - (has_checksum ? 4 : 0)

    while msg_view.pos < limit_pos
      payload_type = msg_view.read_bytes(UInt8, IO::ByteFormat::LittleEndian)

      case payload_type
      when 0_u8
        payload = BSON.new(msg_view)
        @sections << SectionBody.new(payload)
      when 1_u8
        marker = msg_view.pos
        sequence_size = msg_view.read_bytes(Int32, IO::ByteFormat::LittleEndian)

        sequence_identifier = msg_view.gets('\0', chomp: true)
        raise Mongo::Error.new("Invalid OP_MSG: EOF while reading sequence identifier") unless sequence_identifier

        contents = Array(BSON).new

        while msg_view.pos - marker < sequence_size
          contents << BSON.new(msg_view)
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

    err_label_set = cached_body["errorLabels"]?.try { |labels|
      Set(String).new(Array(String).from_bson(labels))
    } || Set(String).new

    if cached_body["ok"] == 1
      if errors = cached_body["writeErrors"]?
        Mongo::Error::CommandWrite.new(errors.as(BSON), error_labels: err_label_set)
      elsif write_error = cached_body["writeConcernError"]?
        Mongo::Error::WriteConcern.new(write_error.as(BSON), error_labels: err_label_set)
      end
    else
      err_msg = cached_body["errmsg"]?.try(&.as(String))
      err_code_name = cached_body["codeName"]?.try(&.as(String))
      err_code = cached_body["code"]?
      details = cached_body["errInfo"]?.try(&.as(BSON))
      Mongo::Error::Command.new(err_code, err_code_name, err_msg, details, error_labels: err_label_set)
    end
  end

  def safe_payload(command)
    cached_body = body
    if command.is_a?(Commands::Hello) && cached_body["speculativeAuthenticate"]?
      BSON.new
    else
      payload = BSON.new(cached_body)
      each_sequence do |key, contents|
        payload[key] = contents
      end
      payload
    end
  end
end
