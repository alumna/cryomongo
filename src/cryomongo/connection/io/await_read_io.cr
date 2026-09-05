# :nodoc:
# Wait for data in short slices. A slice timeout stays inside read(), so
# Message.new does not unwind after a partial header or body.
#
# Darwin kqueue can fire a single long socket timeout early (CSOT bulkWrite
# then sees two inserts instead of three). A slice timeout is retried until
# *deadline*. Darwin often raises Socket::Error / ETIMEDOUT instead of
# IO::TimeoutError. Retry that errno here too. Do not retry ECONNRESET.
# When the deadline has passed, raise IO::TimeoutError so CSOT maps it to
# Error::Timeout. A failPoint blockConnection must hit that deadline
# (legacy socketTimeoutMS or leftover timeoutMS), not be retried until
# connectTimeoutMS. Do not lengthen official timeoutMS waits.
#
# On Darwin a premature kqueue timeout still consumes the slice of leftover
# timeoutMS. A 100ms slice burns a 200ms budget before getMore / the 3rd
# insert. Darwin slices are 10ms. Linux stays at 100ms. A single wait until
# the remaining deadline is the Wave 34 hole (kqueue fires early).
#
# Do not Fiber.yield after a slice timeout. Fiber.yield is EventLoop.sleep(0).
# Darwin kqueue treats Time::Span.zero as now (Wave 34). That wait can burn
# leftover timeoutMS before the next read, so the 2nd find / getMore never
# starts (timeoutMS 75 / blockTimeMS 50). The inner read already yields in
# wait_readable. A tight 0ms timer still calls LibC.read first, so data that
# arrived during the failPoint is not skipped. Do not spin a 0ms wait until
# leftover is 0 before send (wrap_command_io still refuses a 0 leftover).
class Mongo::Connection::AwaitReadIO < IO
  {% if flag?(:darwin) %}
    SLICE = 10.milliseconds
  {% else %}
    SLICE = 100.milliseconds
  {% end %}

  def initialize(@inner : IO, @raw : ::Socket, @deadline : Time::Instant?, @connection : Mongo::Connection)
  end

  def read(slice : Bytes) : Int32
    loop do
      if @connection.interrupted? || @inner.closed?
        raise IO::Error.new("Closed stream")
      end
      # True when leftover is already 0. Still try one read: bytes may
      # already be in the kernel from the failPoint unblocking.
      expired = false
      if deadline = @deadline
        left = deadline - Time.instant
        if left <= Time::Span.zero
          expired = true
          # Immediate wait. Crystal 0 is now on Darwin. LibC.read still
          # runs first (non-blocking socket), so this is a last look.
          wait = Time::Span.zero
        else
          wait = left < SLICE ? left : SLICE
        end
      else
        wait = SLICE
      end
      if @connection.interrupted?
        wait = 1.millisecond
        expired = false
      end
      @raw.read_timeout = wait
      @raw.write_timeout = wait
      inner = @inner
      unless inner.same?(@raw)
        if inner.responds_to?(:read_timeout=)
          inner.read_timeout = wait
        end
        if inner.responds_to?(:write_timeout=)
          inner.write_timeout = wait
        end
      end
      # interrupt() may have set 1ms, then this loop wrote the slice back.
      # Recheck so close does not start another full slice.
      if @connection.interrupted? || @inner.closed?
        raise IO::Error.new("Closed stream")
      end
      begin
        return @inner.read(slice)
      rescue error : IO::Error
        # IO::TimeoutError is an IO::Error. Darwin kqueue may instead raise
        # IO::Error / Socket::Error with os_error ETIMEDOUT. os_error is nil
        # on a plain TimeoutError; do not use .not_nil!.
        if error.is_a?(IO::TimeoutError) || error.os_error == Errno::ETIMEDOUT
          raise IO::TimeoutError.new("Read timed out") if expired
          next
        end
        raise error
      end
    end
  end

  def write(slice : Bytes) : Nil
    if deadline = @deadline
      raise IO::TimeoutError.new("Write timed out") if deadline - Time.instant <= Time::Span.zero
    end
    @inner.write(slice)
  end

  def flush
    @inner.flush
  end

  def close
    @inner.close
  end

  def closed? : Bool
    @inner.closed?
  end
end
