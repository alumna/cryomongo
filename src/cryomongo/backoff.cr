# Jitter for overload backoff. Tests pin this to 0 or 1.
module Mongo::Backoff
  extend self

  @@lock = Sync::Mutex.new
  @@jitter = -1.0

  # Pin jitter to *value* in `[0, 1]`. Pass a negative number to use random jitter.
  def jitter=(value : Float64) : Nil
    @@lock.synchronize { @@jitter = value }
  end

  def jitter : Float64
    pinned = @@lock.synchronize { @@jitter }
    pinned >= 0.0 ? pinned : Random.rand
  end
end
