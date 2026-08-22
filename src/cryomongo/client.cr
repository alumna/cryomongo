require "socket"
require "wait_group"
require "sync/exclusive"
require "./database"
require "./messages/**"
require "./commands/**"
require "./error"
require "./concerns"
require "./read_preference"
require "./sdam/**"
require "./uri"
require "./handshake"
require "./backoff"
require "./monitoring"
require "./client/*"

# The client which provides access to a MongoDB server, replica set, or sharded cluster.
#
# It maintains management of underlying sockets and routing to individual nodes.
class Mongo::Client
  include WithReadConcern
  include WithWriteConcern
  include WithReadPreference

  alias NetworkError = IO::Error | Socket::Error

  # The mininum wire protocol version supported by this driver.
  MIN_WIRE_VERSION = 6
  # The maximum wire protocol version supported by this driver.
  MAX_WIRE_VERSION = 25

  # :nodoc:
  getter! topology : SDAM::TopologyDescription
  # The set of driver options.
  getter options : Options
  # The current highest seen cluster time for the deployment
  getter cluster_time : Session::ClusterTime?
  # :nodoc:
  getter session_pool : Session::Pool = Session::Pool.new
  # :nodoc:
  protected getter min_heartbeat_frequency : Time::Span = 500.milliseconds

  @monitoring_enabled : Bool
  @closing = Atomic(Bool).new(false)

  @topology_lock = Sync::Mutex.new(:reentrant)
  @cluster_time_lock = Sync::Mutex.new
  # One lock for the address -> pool map. Pool checkout uses its own mutex.
  # Do not hold this lock during handshake or socket I/O.
  @pools = Sync::Exclusive(Hash(String, Mongo::Connection::Pool(Mongo::Connection))).new(
    Hash(String, Mongo::Connection::Pool(Mongo::Connection)).new
  )

  @monitors : Array(SDAM::Monitor) = Array(SDAM::Monitor).new
  @srv_poller : SDAM::SrvPoller? = nil
  @socket_check_interval : Time::Span = 5.seconds
  @last_scan : Time = Time::UNIX_EPOCH
  # Capacity 1 so a topology change that happens just before server selection
  # waits is not lost (unbuffered send would take the else branch and drop).
  @topology_update = Channel(Bool).new(1)
  @commands_observable = Monitoring::Observable(Monitoring::Commands::Event).new
  @sdam_observable = Monitoring::Observable(Monitoring::SDAM::Event).new
  @cmap_observable = Monitoring::Observable(Monitoring::CMAP::Event).new
  # UTF subscribes before monitors run. Constructor events wait here until then.
  @pending_sdam_events = [] of Monitoring::SDAM::Event
  @defer_sdam_events = false
  @handshake_extra = [] of Handshake::DriverInfo
  @handshake_client : BSON? = nil

  # The default auth database is optionally provided as a part of the connection string uri.
  #
  # see: https://docs.mongodb.com/manual/reference/connection-string/
  getter default_auth_db : String

  # Create a mongodb client instance from a mongodb URL.
  #
  # ```
  # require "cryomongo"
  #
  # client = Mongo::Client.new "mongodb://127.0.0.1/?appname=client-example"
  # ```
  def initialize(connection_string : String = "mongodb://localhost:27017", options : Mongo::Options = Mongo::Options.new)
    initialize(connection_string: connection_string, options: options, start_monitoring: true)
  end

  # :nodoc:
  def initialize(connection_string : String = "mongodb://localhost:27017", *, options : Mongo::Options = Mongo::Options.new, start_monitoring = true)
    seeds, @options, @credentials, @default_auth_db = Mongo::URI.parse(connection_string, options)
    @monitoring_enabled = start_monitoring
    @defer_sdam_events = !start_monitoring

    if (w = @options.w) || (w_timeout = @options.w_timeout) || (journal = @options.journal)
      @write_concern = WriteConcern.new(w: w, w_timeout: w_timeout.try(&.total_milliseconds.to_i64), j: journal)
    end

    if read_concern_level = @options.read_concern_level
      @read_concern = ReadConcern.new(level: read_concern_level)
    end

    if (max_s = @options.max_staleness_seconds) && max_s > 0
      pref_mode = @options.read_preference
      if pref_mode.nil? || pref_mode == "primary"
        raise Mongo::Error.new("maxStalenessSeconds cannot be used with read preference primary")
      end
    end

    if read_pref = @options.read_preference
      @read_preference = ReadPreference.new(
        mode: read_pref,
        max_staleness_seconds: @options.max_staleness_seconds,
        tags: @options.read_preference_tags.map do |tags_str|
          BSON.build do |builder|
            tags_str.split(',') do |tag|
              if byte_idx = tag.byte_index(':')
                builder[tag.byte_slice(0, byte_idx)] = tag.byte_slice(byte_idx + 1)
              end
            end
          end
        end
      )
    end

    emit_sdam_event(Monitoring::SDAM::TopologyOpeningEvent.new(self.object_id))

    # An unknown/empty topology representation for the event
    empty_topology = SDAM::TopologyDescription.new(self)

    # Use a local variable to satisfy the compiler's strict non-nil checks
    new_topology = SDAM::TopologyDescription.new(self, seeds.map(&.address), @options)
    @topology = new_topology

    emit_sdam_event(Monitoring::SDAM::TopologyDescriptionChangedEvent.new(
      self.object_id,
      empty_topology,
      new_topology.clone
    ))

    new_topology.servers.each do |server|
      emit_sdam_event(Monitoring::SDAM::ServerOpeningEvent.new(self.object_id, server.address))
      # Load-balanced mode has no monitoring sockets.
      unless @options.load_balanced
        add_monitor(server, start_monitoring: @monitoring_enabled)
      end
    end

    # The spec mandates LoadBalanced topology starts with Unknown servers, emits the
    # ServerOpeningEvent, and then transitions them to LoadBalancer automatically.
    if @options.load_balanced
      previous_topology = new_topology.clone

      new_topology.servers.dup.each do |server|
        lb_desc = server.clone
        lb_desc.type = :load_balancer
        new_topology.replace_description(server, lb_desc)
      end

      emit_sdam_event(Monitoring::SDAM::TopologyDescriptionChangedEvent.new(
        self.object_id, previous_topology, new_topology.clone
      ))
      # No monitors. The seed is already usable: create the pool and mark it ready.
      # Do not fill minPoolSize (load-balanced spec).
      new_topology.servers.each { |server| ready_pool(server) }
    end

    start_srv_poller
    # Later topology events must reach subscribers (legacy SDAM JSON). Constructor
    # events stay in @pending_sdam_events until start_sdam_monitoring.
    @defer_sdam_events = false
  end

  # Frees all the resources associated with a client.
  def close
    @closing.set(true)
    @srv_poller.try(&.close)

    # End sessions while pools are still open. EndSessions needs a socket.
    begin
      @session_pool.close(self)
    rescue e
      Log.warn { "Error while trying to close session pool. #{e}" }
    end

    pools_to_close = @pools.lock { |h|
      pairs = h.to_a
      h.clear
      pairs
    }
    pools_to_close.each do |address, pool|
      pool.close
      emit_cmap_event(Monitoring::CMAP::PoolClosedEvent.new(address))
    rescue e
      Log.warn { "Error while trying to close connection pool. #{e}" }
    end

    monitors = @monitors.dup
    if monitors.size <= 1
      monitors.each do |monitor|
        monitor.close
      rescue e
        Log.warn { "Error while trying to close monitor fiber. #{e}" }
      end
    else
      # Awaitable hello can block until interrupt. Close all monitors together.
      wg = WaitGroup.new
      monitors.each do |monitor|
        wg.add(1)
        spawn do
          monitor.close
        rescue e
          Log.warn { "Error while trying to close monitor fiber. #{e}" }
        ensure
          wg.done
        end
      end
      wg.wait
    end

    # Spec: topology is Unknown before TopologyClosedEvent (last SDAM event).
    if (topo = @topology) && (previous = topo.close_to_unknown)
      emit_sdam_event(Monitoring::SDAM::TopologyDescriptionChangedEvent.new(self.object_id, previous, topo.clone))
    end
    emit_sdam_event(Monitoring::SDAM::TopologyClosedEvent.new(self.object_id))
  end

  ########
  # SDAM #
  ########

  # Subscribes to Server Discovery And Monitoring events.
  def subscribe_sdam(&callback : Monitoring::SDAM::Event -> Nil) : Monitoring::SDAM::Event -> Nil
    @sdam_observable.subscribe(&callback)
  end

  # Unsubscribes from SDAM events.
  def unsubscribe_sdam(callback : Monitoring::SDAM::Event -> Nil) : Nil
    @sdam_observable.unsubscribe(callback)
  end

  # Subscribes to connection pool (CMAP) events.
  def subscribe_cmap(&callback : Monitoring::CMAP::Event -> Nil) : Monitoring::CMAP::Event -> Nil
    @cmap_observable.subscribe(&callback)
  end

  # Unsubscribes from CMAP events.
  def unsubscribe_cmap(callback : Monitoring::CMAP::Event -> Nil) : Nil
    @cmap_observable.unsubscribe(callback)
  end

  # Handshake `client` metadata sent on new connections.
  def handshake_client_document : BSON
    @handshake_client ||= Handshake.client_document(@options.appname, extra: @handshake_extra)
  end

  # Append wrapping-library info to handshake metadata. Existing sockets are not closed.
  def append_metadata(name : String, version : String? = nil, platform : String? = nil) : Nil
    info = Handshake::DriverInfo.new(name, version, platform)
    return if @handshake_extra.includes?(info)
    @handshake_extra << info
    @handshake_client = nil
  end

  # Latest RTT for a server. Used by the SDAM RTT prose test (events skip equal descriptions).
  def server_round_trip_time(address : String) : Time::Span?
    topology.servers.find { |s| s.address == address }.try(&.round_trip_time)
  end

  protected def emit_sdam_event(event : Monitoring::SDAM::Event)
    if @defer_sdam_events
      @pending_sdam_events << event
    else
      @sdam_observable.broadcast(event)
    end
  end

  # Monitor hello events. Skip the event object (and hello reply BSON) when nobody is listening.
  # :nodoc:
  def emit_heartbeat_started(address : String, awaited : Bool) : Nil
    return unless @sdam_observable.has_subscribers?
    emit_sdam_event(Monitoring::SDAM::ServerHeartbeatStartedEvent.new(object_id, address, awaited))
  end

  # :nodoc:
  def emit_heartbeat_succeeded(address : String, duration : Time::Span, reply : BSON, awaited : Bool) : Nil
    return unless @sdam_observable.has_subscribers?
    emit_sdam_event(Monitoring::SDAM::ServerHeartbeatSucceededEvent.new(object_id, address, duration, reply, awaited))
  end

  # :nodoc:
  def emit_heartbeat_failed(address : String, duration : Time::Span, failure : Exception, awaited : Bool) : Nil
    return unless @sdam_observable.has_subscribers?
    emit_sdam_event(Monitoring::SDAM::ServerHeartbeatFailedEvent.new(object_id, address, duration, failure, awaited))
  end

  # UTF: subscribe first, then flush constructor events and start monitors.
  # Production `Client.new` already started monitors; this is a no-op then.
  def start_sdam_monitoring : Nil
    return if @monitoring_enabled
    @monitoring_enabled = true
    @pending_sdam_events.each { |event| @sdam_observable.broadcast(event) }
    @pending_sdam_events.clear
    start_monitoring
  end

  ##################
  # Public Methods #
  ##################

  # Get a newly allocated `Mongo::Database` for the database named *name*.
  def database(name : String) : Database
    Database.new(self, name)
  end

  # Get a newly allocated `Mongo::Database`using the default auth database string
  # optionally provided as a part of the connection string uri.
  #
  # see: https://docs.mongodb.com/manual/reference/connection-string/
  def default_database : Database?
    self.database(name: @default_auth_db) unless @default_auth_db.empty?
  end

  # :ditto:
  def [](name : String) : Database
    database(name)
  end

  # Provides a list of all existing databases along with basic statistics about them.
  #
  # NOTE: [for more details, please check the official MongoDB documentation](https://docs.mongodb.com/manual/reference/command/listDatabases).
  def list_databases(
    *,
    filter = nil,
    name_only : Bool? = nil,
    authorized_databases : Bool? = nil,
    session : Session::ClientSession? = nil,
    timeout_ms : Int64? = nil,
  ) : Commands::ListDatabases::Result
    result = self.command(Commands::ListDatabases, session: session, deadline: Mongo::Deadline.from_timeout_ms(timeout_ms), options: {
      filter:               filter,
      name_only:            name_only,
      authorized_databases: authorized_databases,
    })
    raise Mongo::Error.new("Command failed to return a result") unless result
    result
  end

  # Returns a document that provides an overview of the database’s state.
  #
  # NOTE: [for more details, please check the official MongoDB documentation](https://docs.mongodb.com/manual/reference/command/serverStatus/).
  def status(*, repl : Int32? = nil, metrics : Int32? = nil, locks : Int32? = nil, mirrored_reads : Int32? = nil, latch_analysis : Int32? = nil, session : Session::ClientSession? = nil) : BSON?
    self.command(Commands::ServerStatus, session: session, options: {
      repl:           repl,
      metrics:        metrics,
      locks:          locks,
      mirrored_reads: mirrored_reads,
      latch_analysis: latch_analysis,
    })
  end

  # An administrative command that returns usage statistics for each collection.
  #
  # NOTE: [for more details, please check the official MongoDB documentation](https://docs.mongodb.com/manual/reference/command/top).
  def top : BSON?
    self.command(Commands::Top)
  end

  # Allows a client to observe all changes in a cluster.
  #
  # Returns a change stream on all collections in all databases in a cluster.
  #
  # NOTE: Excludes system collections.
  def watch(
    pipeline : Array = [] of BSON,
    *,
    full_document : String? = nil,
    full_document_before_change : String? = nil,
    show_expanded_events : Bool? = nil,
    resume_after : BSON? = nil,
    max_await_time_ms : Int64? = nil,
    batch_size : Int32? = nil,
    collation : Collation? = nil,
    start_at_operation_time : Time? = nil,
    start_after : BSON? = nil,
    read_concern : ReadConcern? = nil,
    read_preference : ReadPreference? = nil,
    comment = nil,
    session : Session::ClientSession? = nil,
    timeout_ms : Int64? = nil,
  ) : Mongo::ChangeStream::Cursor
    tms = timeout_ms.nil? ? @options.timeout.try(&.total_milliseconds.to_i64) : timeout_ms
    Mongo.check_max_await_vs_timeout(max_await_time_ms, tms)
    ChangeStream::Cursor.new(
      client: self,
      database: "admin",
      collection: 1,
      pipeline: pipeline.map { |elt| BSON.new(elt) },
      full_document: full_document,
      full_document_before_change: full_document_before_change,
      show_expanded_events: show_expanded_events,
      resume_after: resume_after,
      start_after: start_after,
      start_at_operation_time: start_at_operation_time,
      read_concern: read_concern,
      read_preference: read_preference,
      max_time_ms: max_await_time_ms,
      batch_size: batch_size,
      collation: collation,
      comment: comment,
      session: session,
      timeout_ms: tms
    )
  end

  # Starts a new logical session for a sequence of operations.
  #
  # ```
  # client = Mongo::Client.new
  #
  # # First, create a ClientSession which is by default causally consistent.
  # session = client.start_session
  # collection = client["db"]["coll"]
  #
  # # On a side note, it is important to ensure that both read and writes are performed with "majority" concern.
  # collection.read_concern = Mongo::ReadConcern.new(level: "majority")
  # collection.write_concern = Mongo::WriteConcern.new(w: "majority")
  #
  # # Then pass session as the *session* named argument…
  # collection.insert_one({a: 1}, session: session)
  # collection.find_one({a: 1}, session: session)
  #
  # # …and always end the session after using it.
  # session.end
  # ```
  def start_session(*,
                    causal_consistency : Bool? = nil,
                    snapshot : Bool? = nil,
                    snapshot_time : BSON::Timestamp? = nil,
                    default_transaction_options : Session::TransactionOptions? = nil,
                    default_timeout_ms : Int64? = nil) : Session::ClientSession
    Session::ClientSession.new(
      client: self,
      implicit: false,
      causal_consistency: causal_consistency,
      snapshot: snapshot,
      snapshot_time: snapshot_time,
      default_transaction_options: default_transaction_options,
      default_timeout_ms: default_timeout_ms
    )
  end

  ############
  # Internal #
  ############

  protected def get_connection(server_description : SDAM::ServerDescription, wait : Time::Span? = nil) : Mongo::Connection
    # Fallback: a data-bearing server should already have a ready pool from SDAM.
    if server_description.data_bearing? || topology.type.single? || @options.load_balanced
      ready_pool(server_description)
    end
    pool = pool_at(server_description.address) || create_pool(server_description)

    emit_cmap_event(Monitoring::CMAP::ConnectionCheckOutStartedEvent.new(server_description.address))
    checkout_from_pool(pool, server_description, wait)
  end

  # Handshake I/O can still see leftover failCommand closeConnection (same appName
  # as the monitor and RTT sockets). That is connection setup, not the write.
  # Single topology selects Unknown at once, so unlabeled leftover network errors
  # retry until the wait budget ends. A labeled handshake error on a known server
  # is backpressure and fails checkout at once. minPoolSize fill uses the factory
  # directly and does not retry here. Pass the original wait into the pool so
  # waitQueueTimeoutMS still applies (nil means the pool uses its own checkout
  # timeout, not serverSelectionTimeoutMS).
  private def checkout_from_pool(
    pool : Mongo::Connection::Pool(Mongo::Connection),
    server_description : SDAM::ServerDescription,
    wait : Time::Span?,
  ) : Mongo::Connection
    deadline = if wait
                 Time.instant + wait
               else
                 Time.instant + @options.server_selection_timeout
               end
    last_network : Mongo::Error::Network? = nil
    loop do
      leftover = deadline - Time.instant
      if leftover <= Time::Span.zero
        emit_cmap_event(Monitoring::CMAP::ConnectionCheckOutFailedEvent.new(server_description.address, "connectionError"))
        raise last_network || Mongo::Error::Connection.new("Timed out while checking out a connection")
      end
      begin
        conn = pool.checkout(wait)
        emit_cmap_event(Monitoring::CMAP::ConnectionCheckedOutEvent.new(server_description.address, conn.connection_id))
        return conn
      rescue error : Mongo::Error::PoolCleared
        # Closed is terminal. Paused: wait for the monitor to mark ready (first
        # hello, or after a clear). Do not mark the server Unknown.
        if pool.closed? || @closing.get
          emit_cmap_event(Monitoring::CMAP::ConnectionCheckOutFailedEvent.new(server_description.address, "connectionError"))
          raise error
        end
        last_network = error
        leftover_wait = deadline - Time.instant
        if leftover_wait <= Time::Span.zero
          emit_cmap_event(Monitoring::CMAP::ConnectionCheckOutFailedEvent.new(server_description.address, "connectionError"))
          raise error
        end
        # Single can select Unknown at once, so selection does not scan.
        # Wake the monitor or minPoolSize-error waits out heartbeatFrequencyMS.
        @monitors.find(&.server_description.address.== server_description.address).try(&.request_immediate_scan)
        pause_wait = leftover_wait < 50.milliseconds ? leftover_wait : 50.milliseconds
        select
        when @topology_update.receive
        when timeout pause_wait
        end
      rescue error : Mongo::Error::Connection
        emit_cmap_event(Monitoring::CMAP::ConnectionCheckOutFailedEvent.new(server_description.address, "timeout"))
        raise error
      rescue error : Mongo::Error::Network
        fail_known_handshake_overload(error, server_description)
        last_network = error
        Fiber.yield
      rescue error : NetworkError
        wrapped = labeled_handshake_network_error(error)
        unless wrapped.is_a?(Mongo::Error::Network)
          emit_cmap_event(Monitoring::CMAP::ConnectionCheckOutFailedEvent.new(server_description.address, "connectionError"))
          raise wrapped
        end
        fail_known_handshake_overload(wrapped, server_description)
        last_network = wrapped
        Fiber.yield
      rescue error
        emit_cmap_event(Monitoring::CMAP::ConnectionCheckOutFailedEvent.new(server_description.address, "connectionError"))
        raise error
      end
    end
  end

  # Handshake network on a known server is backpressure: fail checkout.
  # Unknown still retries leftover failCommand closeConnection (Phase 3.2).
  private def fail_known_handshake_overload(error : Mongo::Error::Network, server_description : SDAM::ServerDescription) : Nil
    return unless error.retryable_overload?
    live = topology.servers.find { |s| s.address == server_description.address } || server_description
    return if live.type.unknown?
    emit_cmap_event(Monitoring::CMAP::ConnectionCheckOutFailedEvent.new(server_description.address, "connectionError"))
    raise error
  end

  private def pool_at(address : String) : Mongo::Connection::Pool(Mongo::Connection)?
    @pools.lock { |h| h[address]? }
  end

  # Insert an empty paused pool under the map lock (no I/O). CMAP PoolCreatedEvent
  # is emitted once. minPoolSize fill starts from ready_pool after a successful check.
  private def create_pool(server_description : SDAM::ServerDescription) : Mongo::Connection::Pool(Mongo::Connection)
    address = server_description.address
    created = false
    pool = @pools.lock do |h|
      if existing = h[address]?
        existing
      else
        created = true
        new_pool = Mongo::Connection::Pool(Mongo::Connection).new(
          initial_pool_size: 0,
          max_pool_size: @options.max_pool_size,
          max_idle_pool_size: @options.max_pool_size,
          checkout_timeout: @options.wait_queue_timeout.try(&.total_seconds) || 5.0,
          max_idle_time: @options.max_idle_time
        ) do
          establish_connection(server_description)
        end
        h[address] = new_pool
        new_pool
      end
    end
    if created
      emit_cmap_event(Monitoring::CMAP::PoolCreatedEvent.new(address))
    end
    pool
  end

  # After a successful hello: create the pool if needed, emit PoolReadyEvent once,
  # then fill minPoolSize in the background (not on load-balanced).
  protected def ready_pool(server_description : SDAM::ServerDescription) : Nil
    return if server_description.type.unknown? || server_description.type.rs_ghost?
    unless server_description.data_bearing? || topology.type.single? || @options.load_balanced
      return
    end
    pool = create_pool(server_description)
    return unless pool.mark_ready
    emit_cmap_event(Monitoring::CMAP::PoolReadyEvent.new(server_description.address))
    return if @options.load_balanced
    address = server_description.address
    pool.start_min_size(@options.min_pool_size) do |error|
      handle_populate_error(address, error)
    end
  end

  # Shutdown / recovering hello during minPoolSize fill: mark Unknown and clear.
  # Handshake network / timeout (SystemOverloadedError) must not change the description.
  private def handle_populate_error(address : String, error : Exception) : Nil
    return if error.is_a?(Mongo::Error) && error.has_error_label?("SystemOverloadedError")
    desc = topology.servers.find { |s| s.address == address }
    return unless desc
    if error.is_a?(Mongo::Error::Command) && error.state_change?
      apply_state_change_error(desc, error)
    end
  end

  # Handshake plus auth. Created is emitted before hello. Ready is emitted after auth.
  # Hello network / timeout errors get backpressure labels and do not clear the pool.
  # Auth errors in load-balanced mode clear that serviceId. Auth does not get those labels.
  private def establish_connection(server_description : SDAM::ServerDescription) : Mongo::Connection
    connection = nil.as(Mongo::Connection?)
    begin
      opened = Mongo::Connection.new(server_description, @credentials, @options, is_monitor: false)
      connection = opened
      address = server_description.address
      emit_cmap_event(Monitoring::CMAP::ConnectionCreatedEvent.new(address, opened.connection_id))
      legacy = @options.server_api.nil? && !@options.load_balanced
      result, round_trip_time = opened.handshake(
        send_metadata: true,
        appname: @options.appname,
        legacy: legacy,
        client_metadata: handshake_client_document,
        load_balanced: @options.load_balanced == true
      )
      # Connection is a class: copy hello fields that handshake set on this instance.
      opened.service_id = result.serviceId
      opened.handshake_complete = true
      begin
        opened.authenticate
      rescue error
        fail_setup_connection(server_description, opened, error, handshake_complete: true)
      end
      emit_cmap_event(Monitoring::CMAP::ConnectionReadyEvent.new(address, opened.connection_id))
      old_rtt = server_description.type.unknown? ? nil : server_description.round_trip_time
      new_rtt = Connection.average_round_trip_time(round_trip_time, old_rtt)
      new_description = SDAM::ServerDescription.new(address, result, new_rtt)
      # Keep the monitor RTT window. CSOT minRTT uses monitor hellos only.
      new_description.copy_rtt_window(server_description) unless server_description.type.unknown?
      topology.update(server_description, new_description)
      server_description.update(new_description)
      opened
    rescue error
      if conn = connection
        raise error if conn.handshake_complete
        fail_setup_connection(server_description, conn, error, handshake_complete: false)
      end
      raise labeled_handshake_network_error(error)
    end
  end

  private def fail_setup_connection(server_description : SDAM::ServerDescription, connection : Mongo::Connection, error : Exception, handshake_complete : Bool) : NoReturn
    # Auth (hello already done) in load-balanced mode clears that serviceId first.
    if @options.load_balanced && handshake_complete
      if sid = connection.service_id
        clear_connection_pool(server_description, sid)
      end
    end
    emit_cmap_event(Monitoring::CMAP::ConnectionClosedEvent.new(server_description.address, connection.connection_id, "error"))
    connection.close
    unless handshake_complete
      raise labeled_handshake_network_error(error)
    end
    if error.is_a?(IO::Error) || error.is_a?(Socket::Error)
      raise Mongo::Error::Network.new(error)
    end
    raise error
  end

  # CMAP backpressure-enabled: network / timeout during TCP or hello, not DNS
  # lookup and not auth after hello. SDAM then leaves the server description.
  private def labeled_handshake_network_error(error : Exception) : Exception
    wrapped = if error.is_a?(Mongo::Error)
                error
              elsif error.is_a?(IO::Error) || error.is_a?(Socket::Error)
                Mongo::Error::Network.new(error)
              else
                error
              end
    add_handshake_backpressure_labels(wrapped)
    wrapped
  end

  private def add_handshake_backpressure_labels(error : Exception) : Nil
    return unless error.is_a?(Mongo::Error)
    cause = error.cause || error
    return if cause.is_a?(Socket::Addrinfo::Error)
    return unless cause.is_a?(IO::Error) || cause.is_a?(Socket::Error) || error.is_a?(Mongo::Error::Network)
    error.add_error_label("SystemOverloadedError")
    error.add_error_label("RetryableError")
  end

  private def release_connection(connection : Mongo::Connection)
    pool = pool_for(connection)
    reason = pool.try &.release(connection)
    emit_cmap_event(Monitoring::CMAP::ConnectionCheckedInEvent.new(connection.server_description.address, connection.connection_id))
    if reason
      emit_cmap_event(Monitoring::CMAP::ConnectionClosedEvent.new(connection.server_description.address, connection.connection_id, reason))
    end
  end

  # :nodoc:
  def checkin_connection(connection : Mongo::Connection) : Nil
    release_connection(connection)
  end

  # :nodoc:
  def discard_connection(connection : Mongo::Connection) : Nil
    pool = pool_for(connection)
    pool.try &.drop(connection)
    emit_cmap_event(Monitoring::CMAP::ConnectionClosedEvent.new(connection.server_description.address, connection.connection_id, "error"))
  end

  # :nodoc:
  def checked_out_count : Int32
    pools = @pools.lock { |h| h.values.dup }
    n = 0
    pools.each { |pool| n += pool.checked_out_count }
    n
  end

  # :nodoc:
  def mark_cursor_pin(connection : Mongo::Connection) : Nil
    pool_for(connection).try &.mark_cursor(connection)
  end

  # :nodoc:
  def mark_transaction_pin(connection : Mongo::Connection) : Nil
    pool_for(connection).try &.mark_transaction(connection)
  end

  private def pool_for(connection : Mongo::Connection) : Mongo::Connection::Pool(Mongo::Connection)?
    pool_at(connection.server_description.address)
  end

  private def checkout_for_command(
    server_description : SDAM::ServerDescription,
    session : Session::ClientSession,
    provided : Mongo::Connection?,
    deadline : Mongo::Deadline?,
  ) : {Mongo::Connection, Bool}
    deadline.try(&.check!)
    timeout = if d = deadline
                d.infinite? ? @options.socket_timeout : d.remaining
              else
                @options.socket_timeout
              end
    if provided
      provided.apply_timeout(timeout)
      return {provided, false}
    end
    session.drop_dead_pin
    if conn = session.pinned_connection
      conn.apply_timeout(timeout)
      return {conn, false}
    end
    wait = if (d = deadline) && !d.infinite?
             d.remaining
           else
             nil
           end
    begin
      conn = get_connection(server_description, wait)
    rescue error : Mongo::Error::Connection
      if (d = deadline) && !d.infinite?
        raise Mongo::Error::Timeout.new("timed out while checking out a connection", cause: error)
      end
      raise error
    end
    conn.apply_timeout(timeout)
    {conn, true}
  end

  private def start_srv_poller : Nil
    hostname = @options.srv_hostname
    return unless hostname
    return if @options.load_balanced
    return unless @monitoring_enabled
    poller = SDAM::SrvPoller.new(
      self,
      hostname,
      @options.srv_service_name,
      @options.heartbeat_frequency,
      @options.srv_max_hosts
    )
    @srv_poller = poller
    poller.start
  end

  # :nodoc:
  def apply_srv_hosts(addresses : Array(String), srv_max_hosts : Int32) : Nil
    current = topology.servers.map(&.address)
    current_set = Set(String).new(current)
    incoming = Set(String).new(addresses)

    current.each do |addr|
      next if incoming.includes?(addr)
      if desc = topology.remove_srv_seed(addr)
        stop_monitoring(desc)
        close_connection_pool(desc)
      end
    end

    new_hosts = addresses.reject { |addr| current_set.includes?(addr) }
    if srv_max_hosts > 0
      room = srv_max_hosts - topology.servers.size
      if room <= 0
        return
      end
      if new_hosts.size > room
        new_hosts.shuffle!
        new_hosts = new_hosts[0, room]
      end
    end
    new_hosts.each do |addr|
      topology.add_srv_seed(addr)
    end
  end

  protected def close_connection_pool(server_description : SDAM::ServerDescription)
    pool_to_close = @pools.lock do |h|
      h.delete(server_description.address)
    end
    if pool_to_close
      emit_cmap_event(Monitoring::CMAP::PoolClearedEvent.new(server_description.address))
      pool_to_close.close
      emit_cmap_event(Monitoring::CMAP::PoolClosedEvent.new(server_description.address))
    end
  end

  # Network / shutdown error: bump generation, wake waiters, keep the pool.
  # Do not delete the pool. A new pool plus handshake can race with Unknown.
  # interrupt_in_use: close checked-out sockets after the event (monitor timeout).
  protected def clear_pool(server_description : SDAM::ServerDescription, interrupt_in_use : Bool = false) : Nil
    pool = pool_at(server_description.address)
    return unless pool
    emit, to_interrupt = pool.clear(interrupt_in_use: interrupt_in_use)
    if emit
      emit_cmap_event(Monitoring::CMAP::PoolClearedEvent.new(
        server_description.address,
        interrupt_in_use_connections: interrupt_in_use
      ))
    end
    to_interrupt.each(&.interrupt_in_use)
  end

  # Load-balanced: increment generation for one serviceId. Other mongos sockets stay.
  protected def clear_connection_pool(server_description : SDAM::ServerDescription, service_id : BSON::ObjectId) : Nil
    pool = pool_at(server_description.address)
    return unless pool
    emit, to_interrupt = pool.clear(service_id)
    if emit
      emit_cmap_event(Monitoring::CMAP::PoolClearedEvent.new(server_description.address, service_id))
    end
    to_interrupt.each(&.interrupt_in_use)
  end

  protected def emit_cmap_event(event : Monitoring::CMAP::Event)
    @cmap_observable.broadcast(event) if @cmap_observable.has_subscribers?
  end

  protected def on_topology_update
    select
    when @topology_update.send true
    else
      # A notification is already waiting for server selection.
    end

    @topology_lock.synchronize do
      self.topology.servers.each do |server|
        no_monitor = @monitors.none? { |monitor|
          monitor.server_description.address == server.address
        }
        add_monitor(server, start_monitoring: @monitoring_enabled) if no_monitor
      end
    end
  end

  # Keep the highest cluster time this client has seen.
  def advance_cluster_time(cluster_time : Session::ClusterTime) : Nil
    @cluster_time_lock.synchronize do
      current = @cluster_time
      if current.nil? || current < cluster_time
        @cluster_time = cluster_time
      end
    end
  end

  private def gossip_cluster_time(session : Session::ClientSession? = nil)
    # see: https://github.com/mongodb/specifications/blob/master/source/sessions/driver-sessions.rst#gossipping-the-cluster-time
    @cluster_time_lock.synchronize do
      client_time = @cluster_time
      return client_time unless session
      session_time = session.cluster_time
      if session_time && client_time
        session_time > client_time ? session_time : client_time
      else
        session_time || client_time
      end
    end
  end

  private def acknowledged?(args : NamedTuple, session : Session::ClientSession, validate : Bool = true) : Bool
    unacknowledged = false
    if concern = args["options"]?.try(&.["write_concern"]?)
      unacknowledged = concern.unacknowledged?
    end

    if unacknowledged && validate
      if session.is_transaction?
        raise Error::Transaction.new("Transactions do not support unacknowledged write concerns.")
      end
    end

    !unacknowledged
  end
end
