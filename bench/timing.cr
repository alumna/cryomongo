# DriverBench timing helper. Median MB/s uses the spec Nearest Rank percentile.
# Default runs are short. BENCH_FULL=1 stops each task at 100 iterations or 5 minutes.

module DriverBench
  module Timing
    extend self

    TASK_SECONDS = ENV["BENCH_FULL"]? ? 60.0 : 2.0
    MAX_SECONDS  = ENV["BENCH_FULL"]? ? 300.0 : 8.0
    MIN_ITERS    = ENV["BENCH_FULL"]? ? 100 : 8

    record Result, name : String, bytes : Int64, n : Int32, median_s : Float64, mb_s : Float64

    # Class var so --release cannot drop a loop that only builds unused BSON.
    class_property kept : Int64 = 0

    def keep(n : Int64) : Nil
      self.kept = self.kept &+ n
    end

    def run(name : String, bytes : Int64, before : Proc(Nil)? = nil, &) : Result
      times = [] of Float64
      total = Time::Span.zero
      loop do
        before.try &.call
        t = Time.measure { yield }
        times << t.total_seconds
        total += t
        break if times.size >= 100
        break if total.total_seconds >= MAX_SECONDS
        break if times.size >= MIN_ITERS && total.total_seconds >= TASK_SECONDS
      end
      times.sort!
      median = nearest_rank(times, 50)
      score = (bytes / 1_000_000.0) / median
      puts "#{name}: median=#{(median * 1000).round(2)}ms  #{score.round(2)} MB/s  (n=#{times.size})"
      Result.new(name, bytes, times.size, median, score)
    end

    def mean(scores : Array(Float64)) : Float64
      return 0.0 if scores.empty?
      scores.sum / scores.size
    end

    # Spec: i = int(N * p / 100) - 1 on a 0-indexed sorted array.
    def nearest_rank(sorted : Array(Float64), percentile : Int32) : Float64
      n = sorted.size
      return 0.0 if n == 0
      idx = n * percentile // 100
      idx = 1 if idx < 1
      idx = n if idx > n
      sorted[idx - 1]
    end
  end
end
