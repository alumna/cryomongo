# Read a BSON document as a view of an already-read message buffer.
# The slice stays valid while *buffer* is alive. OpMsg / OpReply wrap that
# buffer in a heap class (OwnedReceive). Bytes? on a struct is not a Darwin
# GC root; interior BSON.view slices are not either.
module Mongo::Messages
  def self.read_bson_view(buffer : Bytes, io : IO::Memory) : BSON
    pos = io.pos
    remaining = buffer.size - pos
    raise Mongo::Error.new("Invalid message: truncated BSON") if remaining < 5

    size = IO::ByteFormat::LittleEndian.decode(Int32, buffer[pos, 4])
    raise Mongo::Error.new("Invalid message: bad BSON size #{size}") if size < 5 || size > remaining

    io.pos = pos + size
    BSON.view(buffer[pos, size])
  rescue error : BSON::Error
    raise Mongo::Error.new(error.message || "Invalid BSON")
  end
end
