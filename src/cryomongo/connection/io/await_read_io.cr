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
# sit in wait_readable until the failPoint unblocks (Shape B). Slices stay
# 10ms so one early fire cannot burn a 200ms budget. Do not wait the
# remaining leftover Instant as one kqueue wait.
# GitHub `baa1c0f`: closer SHUT_RD then last-read still left gridfs Shape A
# 8/8 (wrap leftover Instant 62–70ms, got one find). Darwin `shutdown` does
# not keep those kernel bytes; inner.read after SHUT can return 0/EOF.
# Do not SHUT to wake wait_readable. The closer stays a no-op.
# GitHub `c119912` replaced this wait with LibC.read + sleep and ignored
# `interrupted?`. cancel_check only sets the flag (no shutdown). Streaming
# hello then ran out heartbeatFrequencyMS (~10s) and macOS jobs hit the
# 45 minute cap. GitHub `8cb330d` checked the flag inside that sleep poll.
# Run `37106011512`: the 10s hang was gone, and every Darwin test paid
# ~0.4–1.5s because the poll does not wake when bytes arrive. Raw sockets
# use this sliced wait_readable again (wake on bytes, or on the slice
# timer). `interrupt` sets a 1ms read_timeout, which wakes the in-flight
# wait; the next loop sees the flag. A streaming hello therefore notices
# cancel within one slice. Non-CSOT: slice timeout at the deadline raises
# before taking kernel bytes. CSOT timeout sets `interrupt` with no
# shutdown so close() drops the pin. Linux stays on this same loop.
#
# GitHub `5e6eb21` / `37114381669`: Darwin CSOT `wait_readable` returned
# 42–136ms after the deadline. `waited_ms + leftover_at_timeout_ms` equals
# the wrap leftover, and leftover at the raise was negative. The 50ms
# block fits in the ~69ms budget. Darwin CSOT raw reads therefore
# `LibC.read` (non-blocking) and sleep one 10ms slice. The clock decides
# expiry. Bytes already in the kernel return at once, including one slice
# after the deadline. No shutdown. Handshakes, streaming hellos, and
# non-CSOT reads stay on `wait_readable`. GitHub `8cb330d` slept on every
# read and each macOS test paid ~0.4–1.5s.
#
# GitHub `88092b7` / `37117968709`: that poll reaches the deadline and
# `LibC.read` is still empty (bulkWrite waited ~200ms against a 120ms
# block). Do not sleep longer. Bytes already in Crystal's socket buffer,
# or still queued in the kernel (`FIONREAD`) when `read` returned
# `EAGAIN`, are returned with no extra wait. A timeout records
# `maxTimeMS`, bytes read, `FIONREAD`, buffered bytes, and wall time.
# GitHub `d5a7977` / `37136012191`: a fixed 3-argument `ioctl` is wrong
# on arm64 Darwin (the third argument is variadic, passed on the stack).
# `fionread=0` was the pre-zeroed local, and the four replicaset and
# sharded jobs then died with SIGTRAP. The call is variadic now. A
# failed ioctl records `fionread_errno`. Do not sleep longer.
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
  # Set only when a CSOT read raises. Cleared on the next CSOT wrap.
  # waited is from the first read of this wrap until the raise.
  # leftover_at_timeout is deadline minus now at the raise (negative if late).
  # wall_waited is Time.utc over that same span (server blockTimeMS is wall
  # time). max_time_ms is the value appended to the command, or nil when
  # the spec says not to send it. csot_bytes / fionread / fionread_errno /
  # buffered / same_fd are set only by the Darwin CSOT poll.
  # fionread_errno is 0 when ioctl succeeded, the libc errno when it
  # returned -1, and nil when this read never called ioctl.
  class_property recorded_waited : Time::Span? = nil
  class_property recorded_leftover_at_timeout : Time::Span? = nil
  class_property recorded_wall_waited : Time::Span? = nil
  class_property recorded_max_time_ms : Int64? = nil
  class_property recorded_csot_bytes : Int64? = nil
  class_property recorded_fionread : Int32? = nil
  class_property recorded_fionread_errno : Int32? = nil
  class_property recorded_buffered : Int32? = nil
  class_property recorded_same_fd : Bool? = nil

  def self.clear_csot_read_timeout : Nil
    self.recorded_waited = nil
    self.recorded_leftover_at_timeout = nil
    self.recorded_wall_waited = nil
    self.recorded_max_time_ms = nil
    self.recorded_csot_bytes = nil
    self.recorded_fionread = nil
    self.recorded_fionread_errno = nil
    self.recorded_buffered = nil
    self.recorded_same_fd = nil
  end

  # Fields for a CSOT read that raised. Empty when this read did not time out.
  def self.csot_timeout_detail : String
    parts = [] of String
    if span = recorded_waited
      parts << "waited_ms=#{span.total_milliseconds}"
    end
    if span = recorded_leftover_at_timeout
      parts << "leftover_at_timeout_ms=#{span.total_milliseconds}"
    end
    if span = recorded_wall_waited
      parts << "wall_ms=#{span.total_milliseconds}"
    end
    if ms = recorded_max_time_ms
      parts << "max_time_ms=#{ms}"
    else
      parts << "max_time_ms=none"
    end
    if bytes = recorded_csot_bytes
      parts << "csot_bytes=#{bytes}"
    else
      parts << "csot_bytes=none"
    end
    if queued = recorded_fionread
      parts << "fionread=#{queued}"
    else
      parts << "fionread=none"
    end
    if errno = recorded_fionread_errno
      parts << "fionread_errno=#{errno}"
    else
      parts << "fionread_errno=none"
    end
    if buffered = recorded_buffered
      parts << "buffered=#{buffered}"
    else
      parts << "buffered=none"
    end
    if same = recorded_same_fd
      parts << "same_fd=#{same ? 1 : 0}"
    else
      parts << "same_fd=none"
    end
    parts.join(' ')
  end

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
    # First read() of this wrap. The write happens before that.
    @wait_started = nil
    @wait_started_utc = nil
    {% if flag?(:darwin) %}
      @csot_bytes = 0_i64
    {% end %}
  end

  getter deadline : Time::Instant?

  @last_read_until : Time::Instant?
  @wait_started : Time::Instant?
  @wait_started_utc : Time?
  {% if flag?(:darwin) %}
    @csot_bytes : Int64 = 0_i64
  {% end %}

  def read(slice : Bytes) : Int32
    @wait_started ||= Time.instant
    @wait_started_utc ||= Time.utc
    {% if flag?(:darwin) %}
      # CSOT only. wait_readable on this path returned 42–136ms late
      # (GitHub `5e6eb21`). Non-CSOT, handshake, and streaming hello stay
      # on the loop below.
      if @csot && @inner.same?(@raw)
        return read_csot_poll(slice)
      end
    {% end %}
    # Handshake, streaming hello, non-CSOT, TLS, and Linux. Bytes wake
    # the fiber through wait_readable. A slice timer is the backstop.
    loop do
      leftover_expired = deadline_expired?
      # Darwin leftover Instant closer already waited leftover Instant.
      # One LibC.read of kernel bytes (no extra wait). Pool-clear interrupt
      # still raises Closed stream.
      if closer_last_read?(leftover_expired)
        return read_kernel_or_timeout(slice)
      end
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
      leftover_expired = deadline_expired?
      if closer_last_read?(leftover_expired)
        return read_kernel_or_timeout(slice)
      end
      if @connection.interrupted?
        wait = 1.millisecond
        expired = false
      end
      # leftover Instant expired: one LibC.read, no wait_readable. Darwin
      # wait_readable(0) is now or never returns (Shape B).
      if expired && wait <= Time::Span.zero
        return read_kernel_or_timeout(slice)
      end
      apply_wait(wait)
      leftover_expired = deadline_expired?
      if closer_last_read?(leftover_expired)
        return read_kernel_or_timeout(slice)
      end
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
        leftover_expired = deadline_expired?
        if closer_last_read?(leftover_expired)
          return read_kernel_or_timeout(slice)
        end
        if slice_timeout?(error)
          raise_read_timeout if expired
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

  private def deadline_expired? : Bool
    if deadline = @deadline
      (deadline - Time.instant) <= Time::Span.zero
    else
      false
    end
  end

  # Darwin CSOT raw socket. Non-blocking LibC.read, then sleep one slice.
  # Expiry is Time.instant, not the moment wait_readable returns. Bytes
  # already in the kernel are returned, including one slice after the
  # deadline (the reply arrived during that sleep). No shutdown.
  # Crystal's read buffer and a final FIONREAD check are not a longer wait:
  # they only return bytes that are already queued.
  {% if flag?(:darwin) %}
  private def read_csot_poll(slice : Bytes) : Int32
    self.class.recorded_same_fd = true
    loop do
      if @connection.interrupted_by_clear? || @inner.closed? || @connection.interrupted?
        raise IO::Error.new("Closed stream")
      end
      if n = take_buffered(slice)
        @got_data = true
        @csot_bytes += n
        return n
      end
      expired = deadline_expired?
      ret = read_raw(slice)
      if ret > 0
        @got_data = true
        @csot_bytes += ret
        return ret
      end
      if ret == 0
        raise_read_timeout if expired
        raise IO::Error.new("Closed stream")
      end
      if expired
        if n = take_kernel_if_pending(slice)
          @got_data = true
          @csot_bytes += n
          return n
        end
        raise_read_timeout
      end
      wait = csot_slice_wait
      if wait <= Time::Span.zero
        if n = take_kernel_if_pending(slice)
          @got_data = true
          @csot_bytes += n
          return n
        end
        raise_read_timeout
      end
      sleep wait
    end
  end

  # LibC.read. Positive is a byte count. 0 is EOF. -1 is EAGAIN
  # (caller sleeps or raises). EINTR retries here. A hard error raises.
  private def read_raw(slice : Bytes) : Int32
    loop do
      ret = LibC.read(@raw.fd, slice.to_unsafe.as(Void*), LibC::SizeT.new(slice.size))
      return ret.to_i if ret >= 0
      err = Errno.value
      next if err == Errno::EINTR
      return -1 if err == Errno::EAGAIN || err == Errno::EWOULDBLOCK || err == Errno::ETIMEDOUT
      raise IO::Error.from_os_error("read", err)
    end
  end

  # Bytes a previous buffered read already took out of the kernel.
  # Empty buffer returns nil. Does not call read, so it cannot wait.
  private def take_buffered(slice : Bytes) : Int32?
    inner = @inner
    return nil unless inner.is_a?(::Socket)
    n = inner.mongo_take_buffered(slice)
    n > 0 ? n : nil
  end

  # FIONREAD > 0 means the kernel has bytes this poll's read missed.
  # One more read, then recv. No sleep.
  private def take_kernel_if_pending(slice : Bytes) : Int32?
    queued = kernel_queued
    return nil if queued.nil? || queued <= 0
    n = read_raw(slice)
    return n if n > 0
    # MSG_DONTWAIT so this cannot block if the fd is not O_NONBLOCK.
    recvd = LibC.recv(@raw.fd, slice.to_unsafe.as(Void*), LibC::SizeT.new(slice.size), 0x80)
    return recvd.to_i if recvd > 0
    nil
  end

  private def probe_kernel_queued : Nil
    kernel_queued
  end

  # Darwin arm64 passes a variadic ioctl's third argument on the stack.
  # A fixed third argument stays in a register, libc writes the count
  # through some other address, and this local (still 0) is what we log.
  # GitHub d5a7977 / 37136012191: fionread=0 on the four cells that then
  # died with SIGTRAP, fionread=none where ioctl returned -1.
  private def kernel_queued : Int32?
    pending = uninitialized LibC::Int
    pending = 0
    ret = MongoCsotProbe.ioctl(@raw.fd, 0x4004667f_u64, pointerof(pending))
    if ret == -1
      self.class.recorded_fionread = nil
      self.class.recorded_fionread_errno = Errno.value.value.to_i32
      return nil
    end
    queued = pending.to_i32
    self.class.recorded_fionread = queued
    self.class.recorded_fionread_errno = 0
    queued
  end

  private def csot_slice_wait : Time::Span
    if deadline = @deadline
      left = deadline - Time.instant
      return Time::Span.zero if left <= Time::Span.zero
      left < SLICE ? left : SLICE
    else
      SLICE
    end
  end
  {% end %}

  # CSOT: mark the pin so close() drops it and killCursors uses a fresh
  # leftover Instant. No shutdown. Non-CSOT stays a plain socket timeout.
  # Linux does not set the flag here (Ubuntu 24/24 already closes the socket
  # in the command rescue). Darwin only: GitHub `8cb330d`.
  private def raise_read_timeout : NoReturn
    if @csot
      if started = @wait_started
        self.class.recorded_waited = Time.instant - started
      end
      if started = @wait_started_utc
        self.class.recorded_wall_waited = Time.utc - started
      end
      if deadline = @deadline
        self.class.recorded_leftover_at_timeout = deadline - Time.instant
      end
      {% if flag?(:darwin) %}
        if self.class.recorded_same_fd
          self.class.recorded_csot_bytes = @csot_bytes
          inner = @inner
          if inner.is_a?(::Socket)
            self.class.recorded_buffered = inner.mongo_buffered_unread
          end
          probe_kernel_queued if self.class.recorded_fionread.nil?
        end
      {% end %}
    end
    {% if flag?(:darwin) %}
      @connection.interrupt if @csot && !@connection.interrupted?
    {% end %}
    detail = @csot ? self.class.csot_timeout_detail : ""
    if detail.empty?
      raise IO::TimeoutError.new("Read timed out")
    else
      raise IO::TimeoutError.new("Read timed out #{detail}")
    end
  end

  # Leftover Instant closer woke this read. Last-read kernel bytes that
  # arrived before leftover Instant. Do not last-read a pool-clear interrupt.
  private def closer_last_read?(leftover_expired : Bool) : Bool
    leftover_expired && last_read_sent_csot? && @connection.interrupted? && !@connection.interrupted_by_clear?
  end

  private def read_kernel_or_timeout(slice : Bytes) : Int32
    n = read_kernel_bytes(slice)
    if n > 0
      @got_data = true
      return n
    end
    raise_read_timeout
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
      raise_read_timeout
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

{% if flag?(:darwin) %}
  @[Link("c")]
  lib MongoCsotProbe
    # Darwin FIONREAD (_IOR('f', 127, int) == 0x4004667f). Bytes queued on the fd.
    # ioctl is variadic. On arm64 Darwin the third argument is on the stack.
    fun ioctl(fd : LibC::Int, request : LibC::ULong, ...) : LibC::Int
  end

  class ::Socket
    # Bytes already copied into Crystal's read buffer. Does not touch the fd.
    def mongo_buffered_unread : Int32
      @in_buffer_rem.size
    end

    # Move those bytes into *slice*. Empty buffer returns 0 and does not read.
    def mongo_take_buffered(slice : Bytes) : Int32
      pending = @in_buffer_rem
      return 0 if pending.empty? || slice.empty?
      n = pending.size < slice.size ? pending.size : slice.size
      slice.copy_from(pending.to_unsafe, n)
      @in_buffer_rem += n
      n
    end
  end
{% end %}
