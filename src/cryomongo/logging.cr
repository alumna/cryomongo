require "log"
require "json"

# Spec-defined log components, levels, and structured messages.
# Env: MONGODB_LOG_COMMAND, MONGODB_LOG_TOPOLOGY, MONGODB_LOG_SERVER_SELECTION,
# MONGODB_LOG_CONNECTION, MONGODB_LOG_ALL, MONGODB_LOG_PATH, MONGODB_LOG_MAX_DOCUMENT_LENGTH.
module Mongo::Logging
  # Most severe first. A min level of Debug also includes Error, Warn, and Info.
  enum Severity
    Emergency
    Alert
    Critical
    Error
    Warning
    Notice
    Informational
    Debug
    Trace

    def self.parse_spec(name : String) : self?
      case name.downcase
      when "off"           then nil
      when "emergency"     then Emergency
      when "alert"         then Alert
      when "critical"      then Critical
      when "error"         then Error
      when "warn"          then Warning
      when "notice"        then Notice
      when "info"          then Informational
      when "debug"         then Debug
      when "trace"         then Trace
      else
        nil
      end
    end

    def spec_name : String
      case self
      when .emergency?     then "emergency"
      when .alert?         then "alert"
      when .critical?      then "critical"
      when .error?         then "error"
      when .warning?       then "warn"
      when .notice?        then "notice"
      when .informational? then "info"
      when .debug?         then "debug"
      else
        "trace"
      end
    end

    def crystal : ::Log::Severity
      case self
      when .emergency?, .alert?, .critical? then ::Log::Severity::Fatal
      when .error?                          then ::Log::Severity::Error
      when .warning?                        then ::Log::Severity::Warn
      when .notice?                         then ::Log::Severity::Notice
      when .informational?                  then ::Log::Severity::Info
      when .debug?                          then ::Log::Severity::Debug
      else
        ::Log::Severity::Trace
      end
    end
  end

  enum Component
    Command
    Topology
    ServerSelection
    Connection

    def self.parse_spec(name : String) : self?
      case name
      when "command"         then Command
      when "topology"        then Topology
      when "serverSelection" then ServerSelection
      when "connection"      then Connection
      else
        nil
      end
    end

    def spec_name : String
      case self
      when .command?          then "command"
      when .topology?         then "topology"
      when .server_selection? then "serverSelection"
      else
        "connection"
      end
    end

    def env_key : String
      case self
      when .command?          then "MONGODB_LOG_COMMAND"
      when .topology?         then "MONGODB_LOG_TOPOLOGY"
      when .server_selection? then "MONGODB_LOG_SERVER_SELECTION"
      else
        "MONGODB_LOG_CONNECTION"
      end
    end

    def crystal_log : ::Log
      case self
      when .command?          then Mongo::Log.for("command")
      when .topology?         then Mongo::Log.for("topology")
      when .server_selection? then Mongo::Log.for("serverSelection")
      else
        Mongo::Log.for("connection")
      end
    end
  end

  struct Message
    getter component : Component
    getter severity : Severity
    getter data : Hash(String, JSON::Any)

    def initialize(@component, @severity, @data)
    end
  end

  alias Collector = Message -> Nil

  # Process-wide env configuration. Programmatic UTF collectors do not use this.
  module Config
    extend self

    @@lock = Sync::Mutex.new
    @@levels = {} of Component => Severity
    @@max_document_length : Int32 = 1000
    @@io : IO = STDERR
    @@loaded = Atomic(Bool).new(false)

    def max_document_length : Int32
      load
      @@max_document_length
    end

    def max_document_length=(value : Int32) : Int32
      load
      @@lock.synchronize { @@max_document_length = value }
    end

    def enabled?(component : Component, severity : Severity) : Bool
      load
      if min = @@lock.synchronize { @@levels[component]? }
        severity <= min
      else
        false
      end
    end

    def io : IO
      load
      @@io
    end

    def load : Nil
      return if @@loaded.get
      @@lock.synchronize do
        return if @@loaded.get
        all = Severity.parse_spec(ENV["MONGODB_LOG_ALL"]? || "")
        Component.each do |component|
          if parsed = Severity.parse_spec(ENV[component.env_key]? || "")
            @@levels[component] = parsed
          elsif all
            @@levels[component] = all
          end
        end
        if raw = ENV["MONGODB_LOG_MAX_DOCUMENT_LENGTH"]?
          if n = raw.to_i?
            @@max_document_length = n if n >= 0
          end
        end
        @@io = path_io(ENV["MONGODB_LOG_PATH"]?)
        @@loaded.set(true)
      end
    end

    private def path_io(path : String?) : IO
      return STDERR unless path
      down = path.downcase
      return STDOUT if down == "stdout"
      return STDERR if down == "stderr"
      File.new(path, "a")
    rescue
      STDERR
    end
  end

  # Per-client collectors for UTF observeLogMessages.
  class Sink
    @lock = Sync::Mutex.new
    @collectors = [] of {Component, Severity, Collector}

    def subscribe(component : Component, min_severity : Severity, &collector : Collector) : Nil
      @lock.synchronize { @collectors << {component, min_severity, collector} }
    end

    def collecting?(component : Component, severity : Severity) : Bool
      @lock.synchronize do
        @collectors.any? { |c, min, _| c == component && severity <= min }
      end
    end

    def emit(message : Message) : Nil
      @lock.synchronize do
        @collectors.each do |component, min, collector|
          collector.call(message) if message.component == component && message.severity <= min
        end
      end
    end
  end

  def self.want?(sink : Sink, component : Component, severity : Severity) : Bool
    Config.enabled?(component, severity) ||
      sink.collecting?(component, severity) ||
      component.crystal_log.level <= severity.crystal
  end

  def self.emit(sink : Sink, component : Component, severity : Severity, data : Hash(String, JSON::Any), text : String) : Nil
    if sink.collecting?(component, severity)
      sink.emit(Message.new(component, severity, data))
    end
    if Config.enabled?(component, severity)
      Config.io.puts text
    end
    log = component.crystal_log
    crystal = severity.crystal
    return unless log.level <= crystal
    case crystal
    when .fatal?  then log.fatal { text }
    when .error?  then log.error { text }
    when .warn?   then log.warn { text }
    when .notice? then log.notice { text }
    when .info?   then log.info { text }
    when .debug?  then log.debug { text }
    else
      log.trace { text }
    end
  end

  # Relaxed EJSON, truncated to max document length, with a trailing ellipsis.
  def self.document_json(bson : BSON) : String
    json = bson.to_json
    max = Config.max_document_length
    return json if json.size <= max
    "#{json[0, max]}..."
  end

  def self.host_port(address : String) : {String, Int64?}
    return {address, nil} if address.ends_with?(".sock")
    colon = address.rindex(':')
    if colon && !address.ends_with?(']')
      host = address.byte_slice(0, colon)
      port = address.byte_slice(colon + 1).to_i64? || 27017_i64
      {host, port}
    else
      {address, 27017_i64}
    end
  end

  def self.any(value : Nil) : JSON::Any
    JSON::Any.new(nil)
  end

  def self.any(value : Bool) : JSON::Any
    JSON::Any.new(value)
  end

  def self.any(value : String) : JSON::Any
    JSON::Any.new(value)
  end

  def self.any(value : Int32) : JSON::Any
    JSON::Any.new(value.to_i64)
  end

  def self.any(value : Int64) : JSON::Any
    JSON::Any.new(value)
  end

  def self.any(value : UInt64) : JSON::Any
    JSON::Any.new(value.to_s)
  end

  def self.any(value : Float64) : JSON::Any
    JSON::Any.new(value)
  end

  def self.duration_ms(span : Time::Span) : JSON::Any
    JSON::Any.new(span.total_milliseconds)
  end

  def self.put(data : Hash(String, JSON::Any), key : String, value) : Nil
    return if value.nil?
    data[key] = any(value)
  end

  def self.closed_reason(reason : String) : String
    case reason
    when "stale"      then "Connection became stale because the pool was cleared"
    when "idle"       then "Connection has been available but unused for longer than the configured max idle time"
    when "error"      then "An error occurred while using the connection"
    when "poolClosed" then "Connection pool was closed"
    else
      reason
    end
  end

  def self.checkout_failed_reason(reason : String) : String
    case reason
    when "timeout"         then "Wait queue timeout elapsed without a connection becoming available"
    when "connectionError" then "An error occurred while trying to establish a new connection"
    when "poolClosed"      then "Connection pool was closed"
    else
      reason
    end
  end
end
