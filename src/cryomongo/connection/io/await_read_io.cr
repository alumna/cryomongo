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
# wait_readable.
#
# When leftover is already 0 at the start of a read, raise at once. Do not
# last-read with wait 0. Crystal 0 is now on Darwin, but LibC.read still
# runs first on a non-blocking socket. If the failPoint already unblocked,
# that last-read returns success and the command succeeds when the test
# needed a socket timeout (legacy timeouts). The same last-read can finish
# the first find after the 75ms budget, so leftover is 0 and wrap_command_io
# used to refuse the 2nd send. Bytes that arrived during a slice that still
# had leftover still return. Finish a message that already started. Do not
# spin a 0ms wait until leftover is 0 before send.
class Mongo::Connection::AwaitReadIO < IO
  {% if flag?(:darwin) %}
    SLICE = 10.milliseconds
  {% else %}
    SLICE = 100.milliseconds
  {% end %}

  def initialize(@inner : IO, @raw : ::Socket, @deadline : Time::Instant?, @connection : Mongo::Connection)
    # True after this wrap has returned at least one byte. Leftover 0 then
    # still reads kernel bytes so a partial OP_MSG can finish.
    @got_data = false
  end

  def read(slice : Bytes) : Int32
    loop do
      if @connection.interrupted? || @inner.closed?
        raise IO::Error.new("Closed stream")
      end
      expired = false
      if deadline = @deadline
        left = deadline - Time.instant
        if left <= Time::Span.zero
          # No last-read when this wrap has not seen a byte yet.
          raise IO::TimeoutError.new("Read timed out") unless @got_data
          # Immediate wait to finish the frame. Crystal 0 is now on Darwin.
          expired = true
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
      apply_wait(wait)
      # interrupt() may have set 1ms, then this loop wrote the slice back.
      # Recheck so close does not start another full slice.
      if @connection.interrupted? || @inner.closed?
        raise IO::Error.new("Closed stream")
      end
      begin
        n = @inner.read(slice)
        @got_data = true if n > 0
        return n
      rescue error : IO::Error
        # IO::TimeoutError is an IO::Error. Darwin kqueue may instead raise
        # IO::Error / Socket::Error with os_error ETIMEDOUT. os_error is nil
        # on a plain TimeoutError; do not use .not_nil!.
        if slice_timeout?(error)
          raise IO::TimeoutError.new("Read timed out") if expired
          # Non-expired slice timed out. Darwin wait_readable does not retry
          # LibC.read, so bytes that arrived during the wait sit in the kernel.
          # Take them before leftover hits 0 on the next loop.
          n = read_kernel_bytes(slice)
          if n > 0
            @got_data = true
            return n
          end
          next
        end
        raise error
      end
    end
  end

  def write(slice : Bytes) : Nil
    # Deadline at first byte: leftover 0 still sends so commandStarted
    # fires. Read then raises without a leftover-0 last-read.
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

  # Same timeout on the raw fd and on TLS if @inner is not the socket.
  private def apply_wait(wait : Time::Span) : Nil
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
  end

  private def slice_timeout?(error : IO::Error) : Bool
    error.is_a?(IO::TimeoutError) || error.os_error == Errno::ETIMEDOUT
  end

  # One LibC.read. Crystal 0 is now; LibC.read still runs first.
  private def read_kernel_bytes(slice : Bytes) : Int32
    apply_wait(Time::Span.zero)
    begin
      @inner.read(slice)
    rescue error : IO::Error
      return 0 if slice_timeout?(error)
      raise error
    end
  end
end
