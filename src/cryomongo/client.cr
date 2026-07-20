require "socket"
require "./database"
require "./messages/**"
require "./commands/**"
require "./error"
require "./concerns"
require "./read_preference"
require "./sdam/**"
require "./uri"
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

  @@topology_lock = Sync::Mutex.new(:reentrant)
  @@connection_pool_lock = Sync::Mutex.new
  @pools : Hash(String, Mongo::Connection::Pool(Mongo::Connection)) = Hash(String, Mongo::Connection::Pool(Mongo::Connection)).new
  @monitors : Array(SDAM::Monitor) = Array(SDAM::Monitor).new
  @socket_check_interval : Time::Span = 5.seconds
  @last_scan : Time = Time::UNIX_EPOCH
  @topology_update = Channel(Nil).new
  @commands_observable = Monitoring::Observable(Monitoring::Commands::Event).new

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

    if (w = @options.w) || (w_timeout = @options.w_timeout) || (journal = @options.journal)
      @write_concern = WriteConcern.new(w: w, w_timeout: w_timeout.try &.milliseconds.to_i64, j: journal)
    end

    if read_concern_level = @options.read_concern_level
      @read_concern = ReadConcern.new(level: read_concern_level)
    end

    if read_pref = @options.read_preference
      @read_preference = ReadPreference.new(
        mode: read_pref,
        max_staleness_seconds: @options.max_staleness_seconds,
        tags: @options.read_preference_tags.map { |tags_str|
          bson = BSON.new
          tags_str.split(',') { |tag|
            if byte_idx = tag.byte_index(':')
              bson[tag.byte_slice(0, byte_idx)] = tag.byte_slice(byte_idx + 1)
            end
          }
          bson
        }
      )
    end

    @topology = SDAM::TopologyDescription.new(self, seeds.map(&.address), @options)
    topology.servers.each { |server|
      add_monitor(server, start_monitoring: start_monitoring)
    }
  end

  # Frees all the resources associated with a client.
  def close
    @pools.each do |_, pool|
      pool.close
    rescue e
      Log.warn { "Error while trying to close connection pool. #{e}" }
    end
    begin
      @session_pool.close(self)
    rescue e
      Log.warn { "Error while trying to close session pool. #{e}" }
    end
    @monitors.each do |monitor|
      monitor.close
    rescue e
      Log.warn { "Error while trying to close monitor fiber. #{e}" }
    end
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
                    causal_consistency : Bool = true,
                    default_transaction_options : Session::TransactionOptions? = nil) : Session::ClientSession
    Session::ClientSession.new(
      client: self,
      implicit: false,
      causal_consistency: causal_consistency,
      default_transaction_options: default_transaction_options
    )
  end

  ############
  # Internal #
  ############

  protected def get_connection(server_description : SDAM::ServerDescription) : Mongo::Connection
    @@connection_pool_lock.synchronize {
      @pools[server_description.address] ||= Mongo::Connection::Pool(Mongo::Connection).new(
        initial_pool_size: @options.min_pool_size,
        max_pool_size: @options.max_pool_size,
        max_idle_pool_size: @options.max_pool_size,
        checkout_timeout: @options.wait_queue_timeout.try(&.seconds.to_f64) || 5.0
      ) do
        connection = Mongo::Connection.new(server_description, @credentials, @options, is_monitor: false)
        result, round_trip_time = connection.handshake(send_metadata: true, appname: @options.appname)
        connection.authenticate
        new_rtt = Connection.average_round_trip_time(round_trip_time, server_description.round_trip_time)
        new_description = SDAM::ServerDescription.new(server_description.address, result, new_rtt)
        topology.update(server_description, new_description)
        server_description.update(new_description)
        connection
      rescue e
        connection.try &.close
        raise e
      end
    }
    @pools[server_description.address].checkout
  end

  private def release_connection(connection : Mongo::Connection)
    @pools[connection.server_description.address]?.try &.release(connection)
  end

  protected def close_connection_pool(server_description : SDAM::ServerDescription)
    @pools[server_description.address]?.try &.close
    @@connection_pool_lock.synchronize {
      @pools.delete server_description.address
    }
  end

  protected def on_topology_update
    loop do
      select
      when @topology_update.send nil
        # Fiber.yield
      else
        break
      end
    end

    @@topology_lock.synchronize {
      self.topology.servers.each { |server|
        no_monitor = @monitors.none? { |monitor|
          monitor.server_description.address.== server.address
        }
        add_monitor(server) if no_monitor
      }
    }
  end

  private def gossip_cluster_time(session : Session::ClientSession? = nil)
    # see: https://github.com/mongodb/specifications/blob/master/source/sessions/driver-sessions.rst#gossipping-the-cluster-time
    if session
      client_time = @cluster_time
      session_time = session.cluster_time
      if !client_time || (session_time && client_time < session_time)
        session_time
      else
        client_time
      end
    else
      @cluster_time
    end
  end

  # :nodoc:
  UNACKNOWLEDGED_WRITE_PROHIBITED_OPTIONS = {
    "hint",
    "collation",
    "bypass_document_validation",
    "array_filters",
  }

  private def acknowledged?(args, session, validate = true)
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
