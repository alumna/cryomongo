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
# leftover Instant is the wait (Command Execution). After write: leftover
# Instant expired → close + Timeout. Else the read wait is remaining leftover
# Instant (sliced). Do not last-read past leftover Instant to help a failPoint
# (wrap+150ms: Shape A later command never starts; Shape B a blocked command
# succeeds).
#
# Darwin kqueue wait_readable does not always expire at leftover Instant.
# Time::Span.zero is now. EVFILT_TIMER data=0 is now. A positive slice can
# sit in wait_readable until the failPoint unblocks (Shape B). After leftover
# Instant expired, one LibC.read for kernel bytes and Timeout — do not
# wait_readable(0). Darwin Connection#arm_leftover_read_closer slices until
# leftover Instant (not one remaining leftover Instant wait, not sleep(0))
# then interrupt_and_wake so a stuck wait_readable wakes. That connection
# is discarded. close() killCursors uses a fresh leftover Instant on a
# usable connection.
#
# leftover 0 at wrap (leftover 0 still send / Darwin non-CSOT / handshake):
# raise at once. Do not last-read with wait 0. Crystal 0 is now on Darwin,
# but LibC.read still runs first on a non-blocking socket. If the failPoint
# already unblocked, that last-read returns success when the test needed a
# socket timeout (legacy timeouts). The same last-read would finish a 2nd
# find sent with leftover already 0.
#
# CSOT wrap created with leftover >0: last-read even if leftover is now 0
# and this wrap has not seen a byte (kernel bytes after Instant 0). Floor
# LAST_READ_WAIT (20ms Instant). Instant-capped once per wrap. Each last-read
# wait is at most LAST_READ_WAIT (not remaining timeoutMS, not Linux SLICE
# 100ms, not wrap+150ms). Then one LibC.read, no wait_readable. leftover 0
# at wrap does not get this wait. Darwin non-CSOT does not last-read (Wave
# 48 Shape B). Linux leftover >0 stays this floor.
#
# Bytes that arrived during a slice that still had leftover still return.
# Finish a message that already started. Do not spin a 0ms wait until
# leftover is 0 before send.
class Mongo::Connection::AwaitReadIO < IO
  {% if flag?(:darwin) %}
    SLICE = 10.milliseconds
  {% else %}
    SLICE = 100.milliseconds
  {% end %}

  # Two Darwin slices. Darwin 0 is now. Instant-capped once per leftover >0 wrap.
  # Do not use SLICE here: Linux SLICE is 100ms and would finish failPoints.
  LAST_READ_WAIT = 20.milliseconds

  # Last CSOT wrap leftover Instant (spec / UTF measurement).
  class_property recorded_leftover_at_wrap : Time::Span = Time::Span.zero
  class_property recorded_leftover_after_write : Time::Span = Time::Span.zero

  def initialize(
    @inner : IO,
    @raw : ::Socket,
    @deadline : Time::Instant?,
    @connection : Mongo::Connection,
    *,
    @csot : Bool = false,
    @leftover_at_wrap : Time::Span = Time::Span.zero,
  )
    # True after this wrap has returned at least one byte. Leftover 0 then
    # still reads kernel bytes so a partial OP_MSG can finish.
    @got_data = false
    # Instant cap for last-read. Nil until leftover first hits 0 on a
    # leftover >0 CSOT wrap.
    @last_read_until = nil
  end

  getter deadline : Time::Instant?

  @last_read_until : Time::Instant?

  def read(slice : Bytes) : Int32
    loop do
      if @connection.interrupted? || @inner.closed?
        raise IO::Error.new("Closed stream")
      end
      expired = false
      if deadline = @deadline
        left = deadline - Time.instant
        if left <= Time::Span.zero
          wait, expired = leftover_zero_wait
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
      # leftover Instant expired: one LibC.read, no wait_readable. Darwin
      # wait_readable(0) is now or never returns (Shape B).
      if expired && wait <= Time::Span.zero
        n = read_kernel_bytes(slice)
        if n > 0
          @got_data = true
          return n
        end
        raise IO::TimeoutError.new("Read timed out")
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
    # fires. leftover 0 at wrap then raises on read (no last-read).
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

  # leftover 0 at wrap / Darwin non-CSOT: raise unless this wrap already
  # returned a byte. CSOT leftover >0 at wrap: last-read Instant (20ms
  # floor for kernel bytes after leftover Instant 0), expired false until
  # that Instant so early kqueue retries. After the Instant, one LibC.read
  # then raise. leftover 0 at wrap never enters this wait. Each last-read
  # wait is at most LAST_READ_WAIT. Do not last-read past leftover Instant
  # (wrap+150ms). Do not wait_readable after leftover Instant expired.
  private def leftover_zero_wait : {Time::Span, Bool}
    unless @got_data || last_read_sent_csot?
      raise IO::TimeoutError.new("Read timed out")
    end
    unless last_read_sent_csot?
      # Finish a partial OP_MSG. Crystal 0 is now; LibC.read still runs.
      return {Time::Span.zero, true}
    end
    until_at = @last_read_until
    unless until_at
      until_at = Time.instant + LAST_READ_WAIT
      @last_read_until = until_at
    end
    extra = until_at - Time.instant
    if extra > Time::Span.zero
      wait = extra < LAST_READ_WAIT ? extra : LAST_READ_WAIT
      {wait, false}
    else
      {Time::Span.zero, true}
    end
  end

  # CSOT command sent with leftover >0: finish this response even if leftover
  # is now 0 and no byte has been returned yet.
  private def last_read_sent_csot? : Bool
    @csot && @leftover_at_wrap > Time::Span.zero
  end

  # One LibC.read. Do not wait_readable: Darwin Time::Span.zero is now, and
  # EVFILT_TIMER data=0 may never resume (leftover Instant expired, failPoint
  # then unblocks). Crystal evented_read LibC.reads first; this path skips
  # the wait. TLS still uses inner.read with wait 0.
  private def read_kernel_bytes(slice : Bytes) : Int32
    if @inner.same?(@raw)
      ret = LibC.read(@raw.fd, slice.to_unsafe.as(Void*), LibC::SizeT.new(slice.size))
      if ret > 0
        return ret.to_i
      end
      return 0 if ret == 0
      err = Errno.value
      return 0 if err == Errno::EAGAIN || err == Errno::EWOULDBLOCK || err == Errno::ETIMEDOUT || err == Errno::EINTR
      raise IO::Error.from_os_error("read", err)
    end
    apply_wait(Time::Span.zero)
    begin
      @inner.read(slice)
    rescue error : IO::Error
      return 0 if slice_timeout?(error)
      raise error
    end
  end
end
