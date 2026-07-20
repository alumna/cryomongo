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

    # Wrap the socket IO to securely bound our reads to this specific message length,
    # preventing any possibility of over-reading into the next message on the wire.
    sized_io = IO::Sized.new(io, read_size: size)

    @flag_bits = Flags.from_value UInt32.from_io(sized_io, IO::ByteFormat::LittleEndian)
    @sections = typeof(@sections).new

    has_checksum = @flag_bits.checksum_present?

    # Calculate exactly how many bytes the payload sections consume
    sections_size = size - 4 - (has_checksum ? 4 : 0)
    bytes_read = 0

    while bytes_read < sections_size
      payload_type = UInt8.from_io(sized_io, IO::ByteFormat::LittleEndian)
      bytes_read += 1

      case payload_type
      when 0_u8
        # Stream the BSON document directly from the socket
        payload = BSON.new(sized_io)
        @sections << SectionBody.new(payload)
        bytes_read += payload.size
      when 1_u8
        sequence_size = Int32.from_io(sized_io, IO::ByteFormat::LittleEndian)

        # Read exactly up to the null byte to avoid any internal IO buffering side-effects
        sequence_identifier = sized_io.gets('\0', chomp: true)
        raise Mongo::Error.new("Invalid OP_MSG: EOF while reading sequence identifier") unless sequence_identifier

        contents = Array(BSON).new

        # Track bytes read for this specific sequence (4 bytes for size + string length + 1 for null byte)
        seq_bytes_read = 4 + sequence_identifier.bytesize + 1
        while seq_bytes_read < sequence_size
          doc = BSON.new(sized_io)
          contents << doc
          seq_bytes_read += doc.size
        end

        @sections << SectionDocumentSequence.new(
          payload: SectionDocumentSequence::SectionPayload.new(
            sequence_identifier, contents
          )
        )
        bytes_read += sequence_size
      else
        raise Mongo::Error.new "Received invalid payload type: #{payload_type}"
      end
    end

    if has_checksum
      @checksum = UInt32.from_io(sized_io, IO::ByteFormat::LittleEndian)
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
    sections.each { |section|
      if section.is_a? SectionDocumentSequence
        yield section.payload.sequence_identifier, section.payload.contents
      end
    }
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
    self.body["ok"] == 1
  end

  def error? : Exception?
    cached_body = self.body

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
      err_msg = cached_body["errmsg"]?.try &.as(String)
      err_code_name = cached_body["codeName"]?.try &.as(String)
      err_code = cached_body["code"]?
      details = cached_body["errInfo"]?.try &.as(BSON)
      Mongo::Error::Command.new(err_code, err_code_name, err_msg, details, error_labels: err_label_set)
    end
  end

  def safe_payload(command)
    cached_body = self.body
    if command.is_a?(Commands::Hello) && cached_body["speculativeAuthenticate"]?
      BSON.new
    else
      payload = BSON.new(cached_body)
      self.each_sequence { |key, contents|
        payload[key] = contents
      }
      payload
    end
  end
end
