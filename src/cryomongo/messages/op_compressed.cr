require "../compression"

# OP_COMPRESSED (opcode 2012). The inner opcode body has no MsgHeader.
module Mongo::Messages
  def self.read_compressed(io : IO, header : Header) : {Header, Bytes}
    size = header.body_size
    raise Mongo::Error.new("Invalid OP_COMPRESSED: truncated header") if size < 9

    buf = Bytes.new(size)
    read_exact(io, buf)

    original = IO::ByteFormat::LittleEndian.decode(Int32, buf[0, 4])
    uncompressed_size = IO::ByteFormat::LittleEndian.decode(Int32, buf[4, 4])
    compressor_id = buf[8]
    compressed = buf + 9

    plain = Compression.inflate(compressor_id, compressed, uncompressed_size)
    inner = Header.new(
      message_length: 16 + uncompressed_size,
      request_id: header.request_id,
      response_to: header.response_to,
      op_code: OpCode.from_value(original)
    )
    {inner, plain}
  end
end
