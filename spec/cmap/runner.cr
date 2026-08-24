require "json"
require "semantic_version"

# Official CMAP cmap-format runner (unit + integration).
module Mongo::Cmap
  class Skip < Exception
  end

  class Runner
    @@mongo_version : SemanticVersion? = nil

    def initialize(@file_path : String)
    end

    def run : Nil
      style = "unit"
      json = JSON.parse(File.read(@file_path))
      style = json["style"].as_s
      if run_on = json["runOn"]?.try(&.as_a)
        raise Skip.new("runOn not met") unless run_on.any? { |req| meets_run_on?(req) }
      end

      client = nil.as(Mongo::Client?)
      connections = {} of String => Mongo::Connection
      uri = cmap_uri(json["poolOptions"]?)
      opened = Mongo::Client.new(uri, start_monitoring: false)
      client = opened
      events = [] of Mongo::Monitoring::CMAP::Event
      events_lock = Sync::Mutex.new
      opened.subscribe_cmap do |event|
        events_lock.synchronize { events << event }
      end

      seed = opened.cmap_seed
      opened.cmap_create_paused_pool(seed)

      threads = {} of String => {Channel(JSON::Any), Channel(Exception?)}
      main_error = nil.as(Exception?)

      begin
        enable_fail_point(json["failPoint"]?) if style == "integration"

        json["operations"].as_a.each do |op|
          if thread_name = op["thread"]?.try(&.as_s?)
            entry = threads[thread_name]?
            raise "unknown thread #{thread_name}" unless entry
            entry[0].send(op)
          else
            run_op(op, opened, seed, connections, events, events_lock, threads)
          end
        end
      rescue error
        main_error = error
      end

      threads.each_value do |queue, _|
        queue.close
      rescue
      end

      if expected_error = json["error"]?
        actual = main_error
        raise Exception.new("TEST_FAILED: expected error #{expected_error.inspect}, got none") unless actual
        unless error_matches?(expected_error, actual)
          raise Exception.new("TEST_FAILED: expected error #{expected_error.inspect}, got #{actual.class}: #{actual.message}")
        end
      elsif main_error
        raise main_error
      end

      ignore = (json["ignore"]?.try(&.as_a) || [] of JSON::Any).map(&.as_s).to_set
      actual_events = events_lock.synchronize { events.dup }
      actual_events.reject! { |event| ignore.includes?(event_type_name(event)) }

      if expected_events = json["events"]?.try(&.as_a)
        expected_events.each_with_index do |expected, index|
          if index >= actual_events.size
            names = actual_events.map { |e| event_type_name(e) }
            raise Exception.new("TEST_FAILED: expected event #{index} #{expected.inspect}, got #{actual_events.size} events: #{names}")
          end
          actual_json = event_json(actual_events[index])
          unless cmap_match?(expected, actual_json)
            raise Exception.new("TEST_FAILED: event #{index} expected #{expected.inspect}, got #{actual_json.inspect}")
          end
        end
      end
    ensure
      disable_fail_point if style == "integration"
      if conns = connections
        conns.each_value do |conn|
          client.try(&.cmap_checkin(conn))
        rescue
        end
      end
      client.try(&.close)
    end

    private def run_op(op : JSON::Any, client : Mongo::Client, seed : Mongo::SDAM::ServerDescription, connections : Hash(String, Mongo::Connection), events : Array(Mongo::Monitoring::CMAP::Event), events_lock : Sync::Mutex, threads : Hash(String, {Channel(JSON::Any), Channel(Exception?)})) : Nil
      case op["name"].as_s
      when "ready"
        client.cmap_ready(seed)
      when "clear"
        interrupt = op["interruptInUseConnections"]?.try(&.as_bool) || false
        client.cmap_clear(seed, interrupt_in_use: interrupt)
      when "close"
        client.cmap_close_pool(seed)
      when "checkOut"
        conn = client.cmap_checkout(seed)
        if label = op["label"]?.try(&.as_s?)
          connections[label] = conn
        end
      when "checkIn"
        label = op["connection"].as_s
        conn = connections.delete(label)
        raise "unknown connection #{label}" unless conn
        client.cmap_checkin(conn)
      when "start"
        target = op["target"].as_s
        queue = Channel(JSON::Any).new(32)
        done = Channel(Exception?).new(1)
        threads[target] = {queue, done}
        spawn do
          begin
            loop do
              run_op(queue.receive, client, seed, connections, events, events_lock, threads)
            end
          rescue Channel::ClosedError
            done.send(nil)
          rescue error
            done.send(error)
          end
        end
      when "wait"
        sleep op["ms"].as_i.milliseconds
      when "waitForThread"
        target = op["target"].as_s
        entry = threads[target]?
        raise "unknown thread #{target}" unless entry
        entry[0].close
        if error = entry[1].receive
          raise error
        end
      when "waitForEvent"
        name = op["event"].as_s
        count = op["count"].as_i
        timeout_ms = op["timeout"]?.try(&.as_i?) || 10_000
        deadline = Time.instant + timeout_ms.milliseconds
        loop do
          n = events_lock.synchronize { events.count { |e| event_type_name(e) == name } }
          break if n >= count
          if Time.instant >= deadline
            raise Exception.new("TEST_FAILED: waitForEvent #{name} timed out (got #{n}, want #{count})")
          end
          sleep 10.milliseconds
        end
      else
        raise "unknown cmap op #{op["name"]}"
      end
    end

    private def cmap_uri(pool_options : JSON::Any?) : String
      uri = mongodb_uri_one_host(ENV["MONGODB_URI"])
      extras = ["directConnection=true"]
      # Pool tests talk to one host. replicaSet / loadBalanced would change topology.
      uri = strip_uri_option(uri, "replicaSet")
      uri = strip_uri_option(uri, "loadBalanced")
      pool_options.try(&.as_h?).try(&.each do |key, value|
        next if key == "backgroundThreadIntervalMS"
        extras << "#{key}=#{json_option_value(value)}"
      end)
      mongodb_uri_with(uri, extras.join("&"))
    end

    private def strip_uri_option(uri : String, name : String) : String
      return uri unless uri.includes?('?')
      base, query = uri.split('?', 2)
      kept = query.split('&').reject { |part| part.downcase.starts_with?(name.downcase + "=") }
      kept.empty? ? base : "#{base}?#{kept.join("&")}"
    end

    private def json_option_value(value : JSON::Any) : String
      if s = value.as_s?
        s
      elsif i = value.as_i?
        i.to_s
      elsif i = value.as_i64?
        i.to_s
      elsif b = value.as_bool?
        b.to_s
      else
        value.to_s
      end
    end

    private def meets_run_on?(req : JSON::Any) : Bool
      version = mongo_version
      if min = req["minServerVersion"]?.try(&.as_s?)
        return false if version < parse_semver(min)
      end
      if max = req["maxServerVersion"]?.try(&.as_s?)
        return false if version > parse_semver(max)
      end
      true
    end

    private def mongo_version : SemanticVersion
      if cached = @@mongo_version
        return cached
      end
      version = if env_version = ENV["MONGODB_VERSION"]?
                  parse_semver(env_version)
                else
                  client = Mongo::Client.new(mongodb_uri_with(ENV["MONGODB_URI"], "serverSelectionTimeoutMS=3000"))
                  begin
                    info = client.command(Mongo::Commands::BuildInfo)
                    parse_semver(info.try(&.version) || "8.0.0")
                  ensure
                    client.close
                  end
                end
      @@mongo_version = version
      version
    end

    private def parse_semver(value : String) : SemanticVersion
      parts = value.split(".")
      while parts.size < 3
        parts << "0"
      end
      SemanticVersion.parse(parts[0..2].join("."))
    end

    private def enable_fail_point(fail_point : JSON::Any?) : Nil
      return unless fail_point
      doc = BSON.from_json(fail_point.to_json)
      admin = Mongo::Cmap::Runner.admin_client
      admin.command(
        Mongo::Commands::ConfigureFailPoint,
        database: "admin",
        fail_point: doc["configureFailPoint"].as(String),
        mode: doc["mode"],
        options: {data: doc["data"]?}
      )
    end

    private def disable_fail_point : Nil
      admin = Mongo::Cmap::Runner.admin_client
      admin.command(
        Mongo::Commands::ConfigureFailPoint,
        database: "admin",
        fail_point: "failCommand",
        mode: "off"
      )
    rescue
    end

    def self.admin_client : Mongo::Client
      @@admin ||= Mongo::Client.new(mongodb_uri_with(mongodb_uri_one_host(ENV["MONGODB_URI"]), "serverSelectionTimeoutMS=3000"))
    end

    def self.close_admin_client : Nil
      @@admin.try(&.close)
      @@admin = nil
    end

    @@admin : Mongo::Client? = nil

    private def error_matches?(expected : JSON::Any, actual : Exception) : Bool
      if type = expected["type"]?.try(&.as_s?)
        ok = case type
             when "PoolClosedError"        then actual.is_a?(Mongo::Error::PoolClosed)
             when "PoolClearedError"       then actual.is_a?(Mongo::Error::PoolCleared)
             when "WaitQueueTimeoutError"  then actual.is_a?(Mongo::Error::Connection)
             else
               actual.class.name.includes?(type)
             end
        return false unless ok
      end
      if message = expected["message"]?.try(&.as_s?)
        text = actual.message || ""
        return false unless text.includes?(message) || message.includes?(text)
      end
      true
    end

    private def event_type_name(event : Mongo::Monitoring::CMAP::Event) : String
      case event
      when Mongo::Monitoring::CMAP::PoolCreatedEvent               then "ConnectionPoolCreated"
      when Mongo::Monitoring::CMAP::PoolReadyEvent                 then "ConnectionPoolReady"
      when Mongo::Monitoring::CMAP::PoolClearedEvent               then "ConnectionPoolCleared"
      when Mongo::Monitoring::CMAP::PoolClosedEvent                then "ConnectionPoolClosed"
      when Mongo::Monitoring::CMAP::ConnectionCreatedEvent         then "ConnectionCreated"
      when Mongo::Monitoring::CMAP::ConnectionReadyEvent           then "ConnectionReady"
      when Mongo::Monitoring::CMAP::ConnectionClosedEvent          then "ConnectionClosed"
      when Mongo::Monitoring::CMAP::ConnectionCheckOutStartedEvent then "ConnectionCheckOutStarted"
      when Mongo::Monitoring::CMAP::ConnectionCheckedOutEvent      then "ConnectionCheckedOut"
      when Mongo::Monitoring::CMAP::ConnectionCheckedInEvent       then "ConnectionCheckedIn"
      when Mongo::Monitoring::CMAP::ConnectionCheckOutFailedEvent  then "ConnectionCheckOutFailed"
      else
        event.class.name
      end
    end

    private def event_json(event : Mongo::Monitoring::CMAP::Event) : JSON::Any
      data = {} of String => JSON::Any
      data["type"] = JSON::Any.new(event_type_name(event))
      data["address"] = JSON::Any.new(event.address)
      case event
      when Mongo::Monitoring::CMAP::PoolCreatedEvent
        options = {} of String => JSON::Any
        event.options.each { |key, value| options[key] = JSON::Any.new(value) }
        data["options"] = JSON::Any.new(options)
      when Mongo::Monitoring::CMAP::PoolClearedEvent
        data["interruptInUseConnections"] = JSON::Any.new(event.interrupt_in_use_connections)
      when Mongo::Monitoring::CMAP::ConnectionCreatedEvent
        data["connectionId"] = JSON::Any.new(event.connection_id)
      when Mongo::Monitoring::CMAP::ConnectionReadyEvent
        data["connectionId"] = JSON::Any.new(event.connection_id)
        data["duration"] = JSON::Any.new(event.duration.total_milliseconds)
      when Mongo::Monitoring::CMAP::ConnectionClosedEvent
        data["connectionId"] = JSON::Any.new(event.connection_id)
        data["reason"] = JSON::Any.new(event.reason)
      when Mongo::Monitoring::CMAP::ConnectionCheckedOutEvent
        data["connectionId"] = JSON::Any.new(event.connection_id)
        data["duration"] = JSON::Any.new(event.duration.total_milliseconds)
      when Mongo::Monitoring::CMAP::ConnectionCheckedInEvent
        data["connectionId"] = JSON::Any.new(event.connection_id)
      when Mongo::Monitoring::CMAP::ConnectionCheckOutFailedEvent
        data["reason"] = JSON::Any.new(event.reason)
        data["duration"] = JSON::Any.new(event.duration.total_milliseconds)
      end
      JSON::Any.new(data)
    end

    private def cmap_match?(expected : JSON::Any, actual : JSON::Any) : Bool
      if expected.as_i? == 42 || expected.as_i64? == 42 || expected.as_s? == "42"
        return !actual.raw.nil?
      end
      if (en = expected.as_i? || expected.as_i64?) && (an = actual.as_i? || actual.as_i64? || actual.as_f?)
        return en.to_f64 == an.to_f64
      end
      if eh = expected.as_h?
        return false unless ah = actual.as_h?
        eh.each do |key, value|
          return false unless cmap_match?(value, ah[key]? || JSON::Any.new(nil))
        end
        true
      elsif ea = expected.as_a?
        return false unless aa = actual.as_a?
        return false unless ea.size <= aa.size
        ea.each_with_index do |value, i|
          return false unless cmap_match?(value, aa[i])
        end
        true
      else
        expected == actual
      end
    end
  end
end
