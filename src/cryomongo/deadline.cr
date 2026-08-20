# Remaining time for one client operation when timeoutMS is set (CSOT).
#
# Uses Time.instant so a wall-clock jump does not shorten or stretch the budget.
struct Mongo::Deadline
  getter start : Time::Instant
  getter limit : Time::Span

  def self.from_options(options : Mongo::Options) : self?
    span = options.timeout
    return nil unless span
    return nil if span <= Time::Span.zero
    new(Time.instant, span)
  end

  def initialize(@start : Time::Instant, @limit : Time::Span)
  end

  def remaining : Time::Span
    left = @limit - @start.elapsed
    left < Time::Span.zero ? Time::Span.zero : left
  end

  def expired? : Bool
    @start.elapsed >= @limit
  end

  def check! : Nil
    raise Mongo::Error::Timeout.new("Operation exceeded timeoutMS (#{@limit.total_milliseconds.to_i}ms)") if expired?
  end
end
