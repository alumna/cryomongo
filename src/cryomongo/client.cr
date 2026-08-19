require "socket"
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

  @topology_lock = Sync::Mutex.new(:reentrant)
  @cluster_time_lock = Sync::Mutex.new
  @connection_pool_lock = Sync::Mutex.new
  @pool_locks = Hash(String, Sync::Mutex).new
  @pools : Hash(String, Mongo::Connection::Pool(Mongo::Connection)) = Hash(String, Mongo::Connection::Pool(Mongo::Connection)).new

  @monitors : Array(SDAM::Monitor) = Array(SDAM::Monitor).new
  @socket_check_interval : Time::Span = 5.seconds
  @last_scan : Time = Time::UNIX_EPOCH
  # Capacity 1 so a topology change that happens just before server selection
  # waits is not lost (unbuffered send would take the else branch and drop).
  @topology_update = Channel(Bool).new(1)
  @commands_observable = Monitoring::Observable(Monitoring::Commands::Event).new
  @sdam_observable = Monitoring::Observable(Monitoring::SDAM::Event).new
  @cmap_observable = Monitoring::Observable(Monitoring::CMAP::Event).new
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
      add_monitor(server, start_monitoring: @monitoring_enabled)
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
    end
  end

  # Frees all the resources associated with a client.
  def close
    # End sessions while pools are still open. EndSessions needs a socket.
    begin
      @session_pool.close(self)
    rescue e
      Log.warn { "Error while trying to close session pool. #{e}" }
    end

    pools_to_close = @connection_pool_lock.synchronize { @pools.values.dup }
    pools_to_close.each do |pool|
      pool.close
    rescue e
      Log.warn { "Error while trying to close connection pool. #{e}" }
    end

    @monitors.dup.each do |monitor|
      monitor.close
    rescue e
      Log.warn { "Error while trying to close monitor fiber. #{e}" }
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
    @sdam_observable.broadcast(event)
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
  ) : Commands::ListDatabases::Result
    result = self.command(Commands::ListDatabases, session: session, options: {
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
    resume_after : BSON? = nil,
    max_await_time_ms : Int64? = nil,
    batch_size : Int32? = nil,
    collation : Collation? = nil,
    start_at_operation_time : Time? = nil,
    start_after : BSON? = nil,
    read_concern : ReadConcern? = nil,
    read_preference : ReadPreference? = nil,
    session : Session::ClientSession? = nil,
  ) : Mongo::ChangeStream::Cursor
    ChangeStream::Cursor.new(
      client: self,
      database: "admin",
      collection: 1,
      pipeline: pipeline.map { |elt| BSON.new(elt) },
      full_document: full_document,
      resume_after: resume_after,
      start_after: start_after,
      start_at_operation_time: start_at_operation_time,
      read_concern: read_concern,
      read_preference: read_preference,
      max_time_ms: max_await_time_ms,
      batch_size: batch_size,
      collation: collation,
      session: session
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
                    default_transaction_options : Session::TransactionOptions? = nil) : Session::ClientSession
    Session::ClientSession.new(
      client: self,
      implicit: false,
      causal_consistency: causal_consistency,
      snapshot: snapshot,
      snapshot_time: snapshot_time,
      default_transaction_options: default_transaction_options
    )
  end

  ############
  # Internal #
  ############

  protected def get_connection(server_description : SDAM::ServerDescription) : Mongo::Connection
    # Fast path: see if the pool already exists
    pool = @connection_pool_lock.synchronize { @pools[server_description.address]? }

    unless pool
      # Get or create a lock specific to this server address
      addr_lock = @connection_pool_lock.synchronize do
        @pool_locks[server_description.address] ||= Sync::Mutex.new
      end

      # Synchronize on the specific address to prevent concurrent initializations for the same server
      # while allowing other servers to initialize their pools in parallel.
      pool = addr_lock.synchronize do
        # Double-check inside the lock
        @connection_pool_lock.synchronize { @pools[server_description.address]? } || begin
          new_pool = Mongo::Connection::Pool(Mongo::Connection).new(
            initial_pool_size: @options.min_pool_size,
            max_pool_size: @options.max_pool_size,
            max_idle_pool_size: @options.max_pool_size,
            checkout_timeout: @options.wait_queue_timeout.try(&.total_seconds) || 5.0,
            max_idle_time: @options.max_idle_time
          ) do
            connection = Mongo::Connection.new(server_description, @credentials, @options, is_monitor: false)
            emit_cmap_event(Monitoring::CMAP::ConnectionCreatedEvent.new(server_description.address, connection.connection_id))
            legacy = @options.server_api.nil? && !@options.load_balanced
            result, round_trip_time = connection.handshake(
              send_metadata: true,
              appname: @options.appname,
              legacy: legacy,
              client_metadata: handshake_client_document,
              load_balanced: @options.load_balanced == true
            )
            connection.authenticate
            old_rtt = server_description.type.unknown? ? nil : server_description.round_trip_time
            new_rtt = Connection.average_round_trip_time(round_trip_time, old_rtt)
            new_description = SDAM::ServerDescription.new(server_description.address, result, new_rtt)
            topology.update(server_description, new_description)
            server_description.update(new_description)
            connection
          rescue e
            connection.try &.close
            raise e
          end

          @connection_pool_lock.synchronize { @pools[server_description.address] = new_pool }
          new_pool
        end
      end
    end

    emit_cmap_event(Monitoring::CMAP::ConnectionCheckOutStartedEvent.new(server_description.address))
    begin
      conn = pool.checkout
      emit_cmap_event(Monitoring::CMAP::ConnectionCheckedOutEvent.new(server_description.address, conn.connection_id))
      conn
    rescue error : Mongo::Error::PoolCleared
      emit_cmap_event(Monitoring::CMAP::ConnectionCheckOutFailedEvent.new(server_description.address, "connectionError"))
      raise error
    rescue error : Mongo::Error::Connection
      emit_cmap_event(Monitoring::CMAP::ConnectionCheckOutFailedEvent.new(server_description.address, "timeout"))
      raise error
    end
  end

  private def release_connection(connection : Mongo::Connection)
    pool = @connection_pool_lock.synchronize { @pools[connection.server_description.address]? }
    pool.try &.release(connection)
    emit_cmap_event(Monitoring::CMAP::ConnectionCheckedInEvent.new(connection.server_description.address, connection.connection_id))
  end

  protected def close_connection_pool(server_description : SDAM::ServerDescription)
    pool_to_close = @connection_pool_lock.synchronize do
      @pool_locks.delete(server_description.address)
      @pools.delete(server_description.address)
    end
    if pool_to_close
      emit_cmap_event(Monitoring::CMAP::PoolClearedEvent.new(server_description.address))
      pool_to_close.close
      emit_cmap_event(Monitoring::CMAP::PoolClosedEvent.new(server_description.address))
    end
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
