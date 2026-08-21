# Reusable receive buffers. OP_MSG BSON.view needs the bytes to stay alive, so a
# successful read keeps the buffer. Failed reads return it. Compression staging
# on Connection uses its own IO::Memory and does not need this pool.
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
    buf.size >= min_size ? buf : Bytes.new(min_size)
  end

  def checkin(buf : Bytes) : Nil
    return if buf.size > 1_048_576
    select
    when @@channel.send(buf)
    else
    end
  end
end
