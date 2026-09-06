require "socket"
require "wait_group"
require "./rtt_monitor"

# :nodoc:
module Mongo::SDAM
  class Monitor
    getter resume_scan = Channel(Nil).new(1)
    getter server_description : ServerDescription

    @heartbeat_frequency : Time::Span = 10.seconds
    @topology : TopologyDescription
    @connection : Mongo::Connection? = nil
    @closed = Atomic(Bool).new(false)
    @scan_started = Atomic(Bool).new(false)
    @scan_requested = Atomic(Bool).new(false)
    @retry_now = false
    @socket_lock = Sync::Mutex.new
    @done = WaitGroup.new
    @rtt : RttMonitor
    @streaming : Bool

    def initialize(
      @client : Mongo::Client,
      @server_description : ServerDescription,
      @credentials : Mongo::Credentials,
      @heartbeat_frequency : Time::Span = 10.seconds,
    )
      @topology = @client.topology
      @streaming = @client.options.streaming_enabled?
      @rtt = RttMonitor.new(@client, @server_description.address, @credentials, @heartbeat_frequency)
    end

    def close_connection(server_description : ServerDescription)
      drop_monitor_socket
    end

    # Close the monitor socket only. The application pool stays.
    def drop_monitor_socket : Nil
      steal_monitor_connection.try(&.interrupt)
    end

    def scan
      return unless @scan_started.compare_and_set(false, true)
      @done.add(1)
      begin
        loop do
          break if @closed.get
          # see: https://github.com/mongodb/specifications/blob/master/source/server-discovery-and-monitoring/server-monitoring.md#multi-threaded-or-asynchronous-monitoring
          # Cooldown is elapsed time. Do not use wall clock.
          before_cooldown = Time.instant + @client.min_heartbeat_frequency
          previous = current_description
          break if previous.nil? || @closed.get

          new_description = check(previous)
          break if @closed.get
          # Application cancelCheck already replaced this server with Unknown.
          # Do not emit a second Unknown or clear the pool again.
          current = current_description
          if current && current.type.unknown? && new_description.type.unknown? && !current.same?(previous)
            @retry_now = true
            @scan_requested.set(false)
            next
          end
          apply_check_result(previous, new_description)

          break if @closed.get

          # Streaming: do not sleep after ok:1 when topologyVersion is present.
          # Network error from a known server: next check at once (new socket).
          if @retry_now || keep_streaming?(new_description)
            @scan_requested.set(false)
            next
          end

          if @scan_requested.swap(false)
            wait_cooldown(before_cooldown)
            next
          end

          select
          when resume_scan.receive
            @scan_requested.set(false)
            break if @closed.get
            # Cooldown only applies to a live monitor that was asked to scan again.
            wait_cooldown(before_cooldown)
          when timeout @heartbeat_frequency
          end
        rescue Channel::ClosedError
          break
        rescue e
          Mongo::Log.error { "Monitoring error: #{e}" }
          Mongo::Log.debug { e.backtrace.join("\n") }
          drop_monitor_socket
        end
      ensure
        @rtt.close
        # Close the monitor socket from this fiber. Do not close the application
        # pool: scan can stop when hello.me replaces localhost with 127.0.0.1,
        # and an in-use insert still sits on the old pool.
        conn = steal_monitor_connection
        conn.try(&.interrupt)
        conn.try { |c| c.close rescue nil }
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
    rescue Channel::ClosedError
    end

    # Application marked this server Unknown. Interrupt awaitable hello and scan now.
    def cancel_check : Nil
      drop_monitor_socket
      request_immediate_scan
    end

    # UTF: hello failCommand does not apply to an in-flight awaitable hello.
    # Shutdown this monitor fd so the next hello is sent now (interrupt() alone
    # can sit out a 100ms read slice on another execution-context thread).
    # cancel_check stays interrupt-only: application sockets may reuse fds.
    def abort_in_progress_hello : Nil
      steal_monitor_connection.try(&.interrupt_and_wake)
      request_immediate_scan
    end

    def check(previous : ServerDescription) : ServerDescription
      @retry_now = false
      result, round_trip_time, from_handshake = do_check(previous)
      description_from_hello(previous, result, round_trip_time, from_handshake)
    rescue error : Exception
      Mongo::Log.error { "Monitoring handshake error: #{error}" }
      Mongo::Log.debug { error.backtrace.join("\n") }
      # see: https://github.com/mongodb/specifications/blob/master/source/server-discovery-and-monitoring/server-monitoring.md#network-or-command-error-during-server-check
      unknown_after_error(previous, error)
    end

    def close
      @closed.set(true)
      steal_monitor_connection.try(&.interrupt_and_wake)
      # Wake RTT now. Waiting for scan first left RTT hello running until
      # the scan fiber's ensure, which added another close wait.
      @rtt.interrupt
      request_immediate_scan
      @resume_scan.close rescue nil
      @done.wait
    end

    private def steal_monitor_connection : Mongo::Connection?
      @socket_lock.synchronize do
        c = @connection
        @connection = nil
        c
      end
    end

    # Sleep until the minHeartbeatFrequency cooldown, but wake if close() runs.
    private def wait_cooldown(until_time : Time::Instant)
      leftover = until_time - Time.instant
      return if leftover <= Time::Span.zero || @closed.get
      select
      when resume_scan.receive
      when timeout leftover
      end
    rescue Channel::ClosedError
    end

    private def current_description : ServerDescription?
      @topology.servers.find(&.address.== @server_description.address)
    end

    private def keep_streaming?(description : ServerDescription) : Bool
      @streaming && !description.type.unknown? && !description.topology_version.nil?
    end

    private def apply_check_result(previous : ServerDescription, new_description : ServerDescription) : Nil
      known = !previous.type.unknown?
      @topology.update(previous, new_description)
      # Clear with the topology update. Only when leaving a known state so UTF
      # sees one poolClearedEvent (a paused pool would emit again).
      # Load-balanced has no monitors; do not pause that pool.
      if new_description.error && known && !@client.options.load_balanced
        @client.clear_pool(previous, interrupt_in_use: new_description.error_is_timeout)
      end
    end

    private def do_check(previous : ServerDescription) : {Commands::Hello::Result, Time::Span, Bool}
      conn = @socket_lock.synchronize { @connection }
      if conn.nil? || conn.socket.closed?
        result, rtt = setup_connection
        return {result, rtt, true}
      end

      begin
        if conn.more_to_come?
          apply_socket_timeout(conn, extra: awaitable_timeout_extra(previous))
          result, rtt = heartbeat(awaited: true) do
            conn.hello(legacy: !conn.use_hello?, exhaust_read: true)
          end
          return {result, rtt, false}
        end
        # Unknown from a state-change error may still carry topologyVersion.
        # Do not await on that value; handshake a new socket instead.
        if @streaming && !previous.type.unknown? && (tv = previous.topology_version)
          apply_socket_timeout(conn, extra: awaitable_timeout_extra(previous))
          result, rtt = heartbeat(awaited: true) do
            conn.hello(
              legacy: !conn.use_hello?,
              topology_version: tv,
              max_await_time_ms: @heartbeat_frequency.total_milliseconds.to_i64
            )
          end
          return {result, rtt, false}
        end

        apply_socket_timeout(conn)
        result, rtt = heartbeat(awaited: false) do
          conn.hello(legacy: !conn.use_hello?)
        end
        {result, rtt, false}
      rescue error
        # Close from this fiber after receive failed. interrupt() only sets a flag.
        close_monitor_conn(conn)
        raise error
      end
    end

    private def close_monitor_conn(conn : Mongo::Connection) : Nil
      @socket_lock.synchronize do
        @connection = nil if @connection.same?(conn)
      end
      conn.close rescue nil
    end

    # Handshake is the first check. Started fires before the socket is opened.
    private def setup_connection : {Commands::Hello::Result, Time::Span}
      address = @server_description.address
      driver_id = Mongo::Connection.next_id
      @client.emit_heartbeat_started(address, false, driver_id, nil)
      started_at = Time.instant
      conn : Mongo::Connection? = nil
      begin
        opened = Mongo::Connection.new(@server_description, @credentials, @client.options, is_monitor: true, connection_id: driver_id)
        conn = opened
        @socket_lock.synchronize { @connection = opened }
        legacy = @client.options.server_api.nil? && !@client.options.load_balanced
        result, rtt = opened.handshake(
          send_metadata: true,
          appname: @client.options.appname,
          legacy: legacy,
          client_metadata: @client.handshake_client_document,
          load_balanced: @client.options.load_balanced == true
        )
        opened.server_connection_id = result.connection_id.try(&.to_i64)
        if @client.want_heartbeat?
          @client.emit_heartbeat_succeeded(address, rtt, result.to_bson, false, driver_id, opened.server_connection_id)
        end
        {result, rtt}
      rescue error
        close_monitor_conn(conn) if conn
        @client.emit_heartbeat_failed(address, started_at.elapsed, error, false, driver_id, conn.try(&.server_connection_id))
        raise error
      end
    end

    # Existing monitor socket: started immediately before send or exhaust read.
    private def heartbeat(awaited : Bool, &) : {Commands::Hello::Result, Time::Span}
      address = @server_description.address
      conn = @socket_lock.synchronize { @connection }
      driver_id = conn.try(&.connection_id)
      server_id = conn.try(&.server_connection_id)
      @client.emit_heartbeat_started(address, awaited, driver_id, server_id)
      started_at = Time.instant
      begin
        result, rtt = yield
        if conn
          conn.server_connection_id = result.connection_id.try(&.to_i64) || conn.server_connection_id
          server_id = conn.server_connection_id
        end
        if @client.want_heartbeat?
          @client.emit_heartbeat_succeeded(address, rtt, result.to_bson, awaited, driver_id, server_id)
        end
        {result, rtt}
      rescue error
        @client.emit_heartbeat_failed(address, started_at.elapsed, error, awaited, driver_id, server_id)
        raise error
      end
    end

    private def description_from_hello(previous : ServerDescription, result : Commands::Hello::Result, round_trip_time : Time::Span, from_handshake : Bool) : ServerDescription
      address = previous.address
      if @streaming
        # Handshake RTT belongs on the dedicated RTT window. Do this before
        # copy so CSOT min RTT sees the sample on this description.
        @rtt.add_sample(round_trip_time) if from_handshake
        if @rtt.started?
          new_description = ServerDescription.new(address, result, @rtt.average)
          @rtt.copy_window_into(new_description)
        else
          new_description = ServerDescription.new(address, result, round_trip_time)
          new_description.record_rtt_sample(round_trip_time)
        end
        if new_description.topology_version && !new_description.type.unknown?
          @rtt.start
        end
        return new_description
      end

      old_rtt = previous.type.unknown? ? nil : previous.round_trip_time
      new_rtt = Mongo::Connection.average_round_trip_time(round_trip_time, old_rtt)
      new_description = ServerDescription.new(address, result, new_rtt)
      new_description.copy_rtt_window(previous) unless previous.type.unknown?
      new_description.record_rtt_sample(round_trip_time)
      new_description
    end

    private def unknown_after_error(previous : ServerDescription, error : Exception) : ServerDescription
      known = !previous.type.unknown?
      description = ServerDescription.new(previous.address)
      description.error = error.message
      description.error_is_timeout = error.is_a?(IO::TimeoutError)
      description.last_update_time = Time.utc
      drop_monitor_socket
      @rtt.reset
      @retry_now = known && error.is_a?(Mongo::Client::NetworkError)
      description
    end

    private def awaitable_timeout_extra(previous : ServerDescription) : Time::Span
      extra = @heartbeat_frequency
      return extra if previous.type.mongos?
      configured = Mongo::Connection.uri_timeout(@client.options.connect_timeout)
      return extra unless configured
      base = configured || 10.seconds
      # mongod 8.0 default minWaitForStreamingHelloMillis is 1000, so an
      # unchanged topologyVersion waits ~1s even when maxAwaitTimeMS is smaller.
      # hello-timeout "extends timeout" is 750ms; floor that whole read to 1.1s
      # so an unpatched mongod does not mark Unknown. interruptInUse is 1s spec
      # sum and must stay at 1s so the monitor times out during the 2s find.
      # Test topologies set minWaitForStreamingHelloMillis=0 so maxAwaitTimeMS
      # is honored (500ms wait, 1s timeout).
      spec_sum = base + extra
      return extra unless spec_sum < 1.second
      1.1.seconds - base
    end

    private def apply_socket_timeout(conn : Mongo::Connection, extra : Time::Span? = nil) : Nil
      # URI default connectTimeoutMS is 10s. 0 means no timeout, including awaitable hello.
      # Darwin kqueue treats Time::Span.zero as an immediate timeout.
      configured = Mongo::Connection.uri_timeout(@client.options.connect_timeout)
      unless configured
        if @client.options.connect_timeout
          conn.apply_timeout(nil)
          return
        end
      end
      base = configured || 10.seconds
      conn.apply_timeout(extra ? base + extra : base)
    end
  end
end
