# :nodoc:
# Wait for data in 100ms slices. A slice timeout stays inside read(), so
# Message.new does not unwind after a partial header or body.
#
# Darwin kqueue can fire a single long socket timeout early (CSOT bulkWrite
# then sees two inserts instead of three). A slice timeout is retried until
# *deadline*. Darwin often raises Socket::Error / ETIMEDOUT instead of
# IO::TimeoutError. Retry that errno here too. Do not retry ECONNRESET.
# When the deadline has passed, raise IO::TimeoutError so CSOT maps it to
# Error::Timeout. Do not lengthen official timeoutMS waits.
class Mongo::Connection::AwaitReadIO < IO
  SLICE = 100.milliseconds

  def initialize(@inner : IO, @raw : ::Socket, @deadline : Time::Instant?, @connection : Mongo::Connection)
  end

  def read(slice : Bytes) : Int32
    loop do
      if @connection.interrupted? || @inner.closed?
        raise IO::Error.new("Closed stream")
      end
      if deadline = @deadline
        left = deadline - Time.instant
        raise IO::TimeoutError.new("Read timed out") if left <= Time::Span.zero
        wait = left < SLICE ? left : SLICE
      else
        wait = SLICE
      end
      if @connection.interrupted?
        wait = 1.millisecond
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
      # interrupt() may have set 1ms, then this loop wrote 100ms back. Recheck
      # so close does not start another full slice.
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
          # Darwin may fire this slice early. Yield so a tight 0ms timer does
          # not spin the worker until the CSOT deadline.
          Fiber.yield
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
