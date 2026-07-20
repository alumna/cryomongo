require "./op_code"

struct Mongo::Messages::Header
  # total message size, including this
  getter message_length : Int32
  # identifier for this message
  getter request_id : Int32
  # requestID from the original request (used in responses from db)
  getter response_to : Int32 = 0
  # request type
  getter op_code : OpCode

  def initialize(@message_length, @request_id, @op_code, @response_to = 0)
  end

  def initialize(io : IO)
    @message_length = io.read_bytes(Int32, IO::ByteFormat::LittleEndian)
    @request_id = io.read_bytes(Int32, IO::ByteFormat::LittleEndian)
    @response_to = io.read_bytes(Int32, IO::ByteFormat::LittleEndian)
    @op_code = OpCode.from_value(io.read_bytes(Int32, IO::ByteFormat::LittleEndian))
  end

  def to_io(io : IO)
    io.write_bytes(@message_length, IO::ByteFormat::LittleEndian)
    io.write_bytes(@request_id, IO::ByteFormat::LittleEndian)
    io.write_bytes(@response_to, IO::ByteFormat::LittleEndian)
    io.write_bytes(@op_code.value, IO::ByteFormat::LittleEndian)
  end

  def body_size
    message_length - 16
  end
end
