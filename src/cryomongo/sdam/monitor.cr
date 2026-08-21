require "socket"
require "wait_group"

# :nodoc:
module Mongo::SDAM
  class Monitor
    getter resume_scan = Channel(Nil).new
    getter server_description : ServerDescription

    @heartbeat_frequency : Time::Span = 10.seconds
    @topology : TopologyDescription
    @connection : Mongo::Connection? = nil
    @closed : Bool = false
    @scan_started : Bool = false
    @scan_requested = Atomic(Bool).new(false)
    @done = WaitGroup.new

    def initialize(
      @client : Mongo::Client,
      @server_description : ServerDescription,
      @credentials : Mongo::Credentials,
      @heartbeat_frequency : Time::Span = 10.seconds,
    )
      @topology = @client.topology
    end

    def get_connection(server_description : ServerDescription) : Mongo::Connection
      conn = @connection
      if !conn || conn.socket.closed?
        conn = Mongo::Connection.new(@server_description, @credentials, @client.options, is_monitor: true)
        legacy = @client.options.server_api.nil? && !@client.options.load_balanced
        conn.handshake(
          send_metadata: true,
          appname: @client.options.appname,
          legacy: legacy,
          client_metadata: @client.handshake_client_document,
          load_balanced: @client.options.load_balanced == true
        )
        @connection = conn
      end
      conn
    end

    def close_connection(server_description : ServerDescription)
      drop_monitor_socket
      @client.close_connection_pool(server_description)
    end

    # Close the monitor socket only. The application pool stays.
    def drop_monitor_socket : Nil
      if (connection = @connection) && !connection.socket.closed?
        connection.socket.close
      end
      @connection = nil
    end

    def scan
      return if @scan_started
      @scan_started = true
      @done.add(1)
      begin
        loop do
          break if @closed
          # see: https://github.com/mongodb/specifications/blob/master/source/server-discovery-and-monitoring/server-monitoring.rst#multi-threaded-or-asynchronous-monitoring
          # Cooldown is elapsed time. Do not use wall clock.
          before_cooldown = Time.instant + @client.min_heartbeat_frequency
          server_to_check = @topology.servers.find(&.address.== @server_description.address)

          break if server_to_check.nil? || @closed

          unless (new_description = check(server_to_check)).nil?
            @topology.update(server_to_check, new_description) unless @closed
          end

          # Close can happen during check(). The immediate-scan signal is then
          # dropped (unbuffered channel + else). Do not wait a full heartbeat.
          break if @closed

          if @scan_requested.swap(false)
            wait_cooldown(before_cooldown)
            next
          end

          select
          when resume_scan.receive
            @scan_requested.set(false)
            break if @closed
            # Cooldown only applies to a live monitor that was asked to scan again.
            wait_cooldown(before_cooldown)
          when timeout @heartbeat_frequency
          end
        rescue e
          Mongo::Log.error { "Monitoring error: #{e}" }
          Mongo::Log.debug { e.backtrace.join("\n") }
          # Monitoring error
        end
      ensure
        close_connection(@server_description)
        @client.stop_monitoring(@server_description)
        @done.done
      end
    end

    def request_immediate_scan
      @scan_requested.set(true)
      select
      when resume_scan.send nil
      else
        # Scan is in check() or already waking. The flag makes the next loop
        # run another check instead of sleeping a full heartbeat.
      end
    end

    def check(server_description : ServerDescription)
      server_description.last_update_time = Time.utc
      connection = get_connection(server_description)
      result, round_trip_time = connection.handshake(legacy: !connection.use_hello?)
      old_rtt = server_description.type.unknown? ? nil : server_description.round_trip_time
      new_rtt = Connection.average_round_trip_time(round_trip_time, old_rtt)
      new_description = ServerDescription.new(server_description.address, result, new_rtt)
      new_description.copy_rtt_window(server_description) unless server_description.type.unknown?
      new_description.record_rtt_sample(round_trip_time)
      new_description
    rescue error : Exception
      Mongo::Log.error { "Monitoring handshake error: #{error}" }
      Mongo::Log.debug { error.backtrace.join("\n") }
      # see: https://github.com/mongodb/specifications/blob/master/source/server-discovery-and-monitoring/server-monitoring.rst#network-or-command-error-during-server-check
      known_state = !server_description.type.unknown?
      description = ServerDescription.new(server_description.address)
      description.error = error.message
      description.last_update_time = server_description.last_update_time
      drop_monitor_socket
      # A known server: clear the application pool. Do not delete it.
      @client.clear_pool(server_description) if known_state
      if known_state && error.is_a? Client::NetworkError
        check(description)
      else
        description
      end
    end

    def close
      @closed = true
      request_immediate_scan
      @done.wait
    end

    # Sleep until the minHeartbeatFrequency cooldown, but wake if close() runs.
    private def wait_cooldown(until_time : Time::Instant)
      leftover = until_time - Time.instant
      return if leftover <= Time::Span.zero || @closed
      select
      when resume_scan.receive
      when timeout leftover
      end
    end
  end
end
