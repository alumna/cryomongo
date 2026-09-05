# Reusable receive staging buffers. Socket code checkouts, reads, copies
# *used* bytes, then checkins (copy_and_checkin). Parse BSON.view of the
# copy only. Nested []? must not alias a buffer another fiber can overwrite
# after checkin (preview_mt). OpMsg / OpReply wrap that copy in a heap
# class (OwnedReceive). Bytes? on a struct is not a Darwin GC root
# (Wave 42). Failed reads also return the buffer. Compression inflate
# uses its own Bytes and does not use this pool.
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

  # One memcpy of the frame, then the staging buffer goes back to the pool.
  # Same copy cost as the old per-document own_payload clone. Do not checkin
  # the returned slice (that would let a later checkout overwrite views).
  # The message must wrap this slice in OwnedReceive. Do not store only
  # Bytes? on the OpMsg struct (that is not a Darwin GC root).
  def copy_and_checkin(pool_buf : Bytes, used : Int32) : Bytes
    begin
      owned = Bytes.new(used)
      # copy_to(Slice) requires target.size >= source.size. The pool buffer
      # is often 16KiB; *used* is the frame. Copy only that prefix.
      owned.copy_from(pool_buf[0, used])
      owned
    ensure
      checkin(pool_buf)
    end
  end
end
