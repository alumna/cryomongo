# Flush-on-write timing log for the unified runner.
# Default path: tmp/utf-timing.log (override with UTF_TIMING_LOG).
# Each line is one event so a live `tail -f` shows progress.
module Mongo::Unified::Timing
  extend self

  @@io : IO::FileDescriptor? = nil
  @@lock = Sync::Mutex.new
  @@suite_started = Time.utc
  @@file_ms = Hash(String, Int64).new
  @@test_ms = [] of {String, String, Int64}

  def start_suite
    @@suite_started = Time.utc
    @@file_ms.clear
    @@test_ms.clear
    line("SUITE", status: "start")
  end

  def finish_suite
    total = elapsed_ms(@@suite_started)
    line("SUITE", status: "done", duration_ms: total, files: @@file_ms.size)
    dump_slowest
    close
  end

  def line(kind : String, **fields)
    parts = ["ts=#{timestamp}", "kind=#{kind}"]
    fields.each do |key, value|
      next if value.nil?
      text = value.to_s
      text = text.gsub('\t', " ").gsub('\n', " ")
      parts << "#{key}=#{quote(text)}"
    end
    message = parts.join('\t')
    @@lock.synchronize do
      io = open_log
      io.puts message
      io.flush
    end
  rescue
    # Timing must never fail a test.
  end

  def record_file(path : String, duration_ms : Int64)
    @@file_ms[path] = duration_ms
  end

  def record_test(path : String, name : String, duration_ms : Int64)
    @@test_ms << {path, name, duration_ms}
  end

  def elapsed_ms(started : Time) : Int64
    (Time.utc - started).total_milliseconds.to_i64
  end

  private def dump_slowest
    io = open_log
    io.puts "ts=#{timestamp}\tkind=SUMMARY\tnote=slowest_files"
    @@file_ms.to_a.sort_by { |_, ms| -ms }.first(20).each do |path, ms|
      io.puts "ts=#{timestamp}\tkind=SLOW_FILE\tfile=#{quote(path)}\tduration_ms=#{ms}"
    end
    io.puts "ts=#{timestamp}\tkind=SUMMARY\tnote=slowest_tests"
    @@test_ms.sort_by { |_, _, ms| -ms }.first(30).each do |path, name, ms|
      io.puts "ts=#{timestamp}\tkind=SLOW_TEST\tfile=#{quote(path)}\tname=#{quote(name)}\tduration_ms=#{ms}"
    end
    io.flush
  end

  private def open_log : IO::FileDescriptor
    if existing = @@io
      return existing
    end
    path = ENV["UTF_TIMING_LOG"]? || "tmp/utf-timing.log"
    dir = File.dirname(path)
    Dir.mkdir_p(dir) unless dir == "." || dir == ""
    @@io = File.open(path, "a")
  end

  private def close
    @@lock.synchronize do
      @@io.try(&.close)
      @@io = nil
    end
  end

  private def timestamp : String
    Time.utc.to_rfc3339(fraction_digits: 3)
  end

  private def quote(value : String) : String
    if value.includes?(' ') || value.includes?('=') || value.includes?('"')
      "\"#{value.gsub('"', "'")}\""
    else
      value
    end
  end
end
