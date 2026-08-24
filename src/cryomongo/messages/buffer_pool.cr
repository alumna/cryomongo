# Reusable receive buffers. After a successful OP_MSG / OP_REPLY parse, BSON
# is copied and the buffer returns here. Failed reads also return it.
# Compression staging on Connection uses its own IO::Memory and does not need
# this pool.
module Mongo::Messages::BufferPool
  extend self

  POOL_SIZE    =      16
  DEFAULT_SIZE = 16_384

  @@channel = Channel(Bytes).new(POOL_SIZE)

  def checkout(min_size : Int32) : Bytes
    buf = nil
    select
    when received = @@channel.receive
      buf = received
    else
      cap = min_size > DEFAULT_SIZE ? min_size : DEFAULT_SIZE
      buf = Bytes.new(cap)
    end
    return buf if buf.size >= min_size
    checkin(buf)
    Bytes.new(min_size)
  end

  def checkin(buf : Bytes) : Nil
    return if buf.size > 1_048_576
    select
    when @@channel.send(buf)
    else
    end
  end
end
