# Remaining time for one client operation when timeoutMS is set (CSOT).
#
# Uses Time.instant so a wall-clock jump does not shorten or stretch the budget.
# limit is nil when timeoutMS=0 (infinite). Unset timeoutMS does not create a deadline.
struct Mongo::Deadline
  getter start : Time::Instant
  # Nil means infinite (URI timeoutMS=0).
  getter limit : Time::Span?

  def self.from_options(options : Mongo::Options) : self?
    span = options.timeout
    return nil unless span
    from_span(span)
  end

  # Operation-level timeoutMS. Nil means inherit from the client. 0 means infinite.
  def self.from_timeout_ms(ms : Int64?) : self?
    return nil if ms.nil?
    raise Mongo::Error.new("timeoutMS must not be negative") if ms < 0
    from_span(ms.milliseconds)
  end

  def self.from_span(span : Time::Span) : self
    raise Mongo::Error.new("timeoutMS must not be negative") if span < Time::Span.zero
    if span == Time::Span.zero
      new(Time.instant, nil)
    else
      new(Time.instant, span)
    end
  end

  def initialize(@start : Time::Instant, @limit : Time::Span?)
  end

  def infinite? : Bool
    @limit.nil?
  end

  def remaining : Time::Span
    if lim = @limit
      left = lim - @start.elapsed
      left < Time::Span.zero ? Time::Span.zero : left
    else
      # Callers that still need a span (socket timeout) use a large value.
      24.hours
    end
  end

  def expired? : Bool
    return false if infinite?
    if lim = @limit
      @start.elapsed >= lim
    else
      false
    end
  end

  def check! : Nil
    raise Mongo::Error::Timeout.new("Operation exceeded timeoutMS") if expired?
  end

  # maxTimeMS is remaining timeout minus the server min RTT, so the server can
  # answer MaxTimeMSExpired before the socket times out.
  # Returns nil when the leftover time is too small to send.
  def max_time_ms(min_rtt : Time::Span) : Int64?
    return nil if infinite?
    left = remaining
    return nil if left <= min_rtt
    ms = (left - min_rtt).total_milliseconds.to_i64
    ms < 1 ? 1_i64 : ms
  end
end
