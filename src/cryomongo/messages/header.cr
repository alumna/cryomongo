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
    buf = uninitialized UInt8[16]
    slice = buf.to_slice
    Messages.read_exact(io, slice)
    @message_length = IO::ByteFormat::LittleEndian.decode(Int32, slice[0, 4])
    @request_id = IO::ByteFormat::LittleEndian.decode(Int32, slice[4, 4])
    @response_to = IO::ByteFormat::LittleEndian.decode(Int32, slice[8, 4])
    @op_code = OpCode.from_value(IO::ByteFormat::LittleEndian.decode(Int32, slice[12, 4]))
  end

  def to_io(io : IO)
    buf = uninitialized UInt8[16]
    slice = buf.to_slice
    IO::ByteFormat::LittleEndian.encode(@message_length, slice[0, 4])
    IO::ByteFormat::LittleEndian.encode(@request_id, slice[4, 4])
    IO::ByteFormat::LittleEndian.encode(@response_to, slice[8, 4])
    IO::ByteFormat::LittleEndian.encode(@op_code.value, slice[12, 4])
    io.write(slice)
  end

  def body_size
    message_length - 16
  end
end
