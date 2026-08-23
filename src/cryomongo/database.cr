require "./client"
require "./collection"
require "./concerns"
require "./read_preference"
require "./gridfs"

# A `Database` provides access to a MongoDB database.
#
# ```
# database = client["database_name"]
# ```
class Mongo::Database
  include WithReadConcern
  include WithWriteConcern
  include WithReadPreference

  # The underlying MongoDB client.
  getter client : Mongo::Client
  # The database name.
  getter name : String
  # CSOT timeoutMS for this database. Nil inherits from the client.
  property timeout_ms : Int64? = nil

  # :nodoc:
  def initialize(@client, @name)
  end

  # Deadline from timeoutMS on this database, or from the client URI.
  def inherited_deadline : Mongo::Deadline?
    if ms = @timeout_ms
      Mongo::Deadline.from_timeout_ms(ms)
    else
      Mongo::Deadline.from_options(@client.options)
    end
  end

  # Execute a command on the server targeting the database.
  #
  # Will automatically set the *database* arguments.
  #
  # See: `Mongo::Client.command`
  def command(
    operation,
    write_concern : WriteConcern? = nil,
    read_concern : ReadConcern? = nil,
    read_preference : ReadPreference? = nil,
    session : Session::ClientSession? = nil,
    deadline : Mongo::Deadline? = nil,
    timeout_ms : Int64? = nil,
    **args,
    &block
  )
    unless timeout_ms.nil?
      if session && session.operation_deadline
        raise Mongo::Error.new("Cannot override timeoutMS inside withTransaction")
      end
      deadline ||= Mongo::Deadline.from_timeout_ms(timeout_ms)
    end
    deadline ||= session.try(&.operation_deadline)
    deadline ||= inherited_deadline
    @client.command(
      operation,
      **args,
      database: @name,
      write_concern: write_concern || @write_concern,
      read_concern: read_concern || @read_concern,
      read_preference: read_preference || @read_preference,
      session: session,
      deadline: deadline,
    ) { |result, cmd_session|
      yield result, cmd_session
    }
  end

  # :ditto:
  def command(
    operation,
    write_concern : WriteConcern? = nil,
    read_concern : ReadConcern? = nil,
    read_preference : ReadPreference? = nil,
    session : Session::ClientSession? = nil,
    **args,
  )
    self.command(
      operation,
      **args,
      write_concern: write_concern,
      read_concern: read_concern,
      read_preference: read_preference,
      session: session,
    ) { |result|
      result
    }
  end

  # Run a raw command on this database. The caller's document is copied.
  # Driver fields (lsid, $db, $clusterTime) are added on the copy.
  # Read and write concern from the database are not applied. Not retryable.
  # If the document already has maxTimeMS and timeoutMS is set, maxTimeMS is overwritten.
  def run_command(
    command,
    *,
    read_preference : ReadPreference? = nil,
    session : Session::ClientSession? = nil,
    timeout_ms : Int64? = nil,
  ) : BSON
    body = command.is_a?(BSON) ? command : BSON.new(command)
    name = Commands::RunCommand.first_key(body)
    # Empty options so mix_read_preference can add $readPreference when the
    # topology needs it. Do not put read_preference in options here: standalone
    # must not send $readPreference even if the caller asked for nearest.
    result = self.command(
      Commands::RunCommand.new(name),
      command_bson: body,
      session: session,
      read_preference: read_preference,
      timeout_ms: timeout_ms,
      options: NamedTuple.new,
    )
    raise Mongo::Error.new("Command failed to return a result") unless result
    result.as(BSON)
  end

  # Run a command that returns a cursor. getMore stays on the same server
  # (and the same load-balanced socket). timeoutMode and cursorType follow CSOT.
  # batch_size, comment, and max_time_ms apply to getMore only.
  def run_cursor_command(
    command,
    *,
    read_preference : ReadPreference? = nil,
    session : Session::ClientSession? = nil,
    timeout_ms : Int64? = nil,
    timeout_mode : Mongo::TimeoutMode? = nil,
    cursor_type : Mongo::CursorType? = nil,
    batch_size : Int32? = nil,
    comment = nil,
    max_time_ms : Int64? = nil,
  ) : Mongo::Cursor
    body = command.is_a?(BSON) ? command : BSON.new(command)
    name = Commands::RunCommand.first_key(body)
    tailable = cursor_type.try { |c| c.tailable? || c.tailable_await? } || false
    await_data = cursor_type.try(&.tailable_await?) || false

    has_timeout = !timeout_ms.nil? || !@timeout_ms.nil? || @client.options.timeout
    if timeout_mode && !has_timeout
      raise Mongo::Error.new("timeoutMode requires timeoutMS")
    end
    if tailable && timeout_mode.try(&.cursor_lifetime?)
      raise Mongo::Error.new("tailable cursors do not support timeoutMode cursorLifetime")
    end
    if timeout_ms && max_time_ms
      raise Mongo::Error.new("timeoutMS and getMore maxTimeMS cannot both be set")
    end
    Mongo.check_max_await_vs_timeout(max_time_ms, timeout_ms || @timeout_ms || @client.options.timeout.try(&.total_milliseconds.to_i64))

    mode = timeout_mode || (tailable ? Mongo::TimeoutMode::Iteration : Mongo::TimeoutMode::CursorLifetime)
    deadline = unless timeout_ms.nil?
                 Mongo::Deadline.from_timeout_ms(timeout_ms)
               else
                 inherited_deadline
               end
    cmd_deadline = if await_data
                     deadline
                   elsif mode.iteration?
                     deadline.try(&.without_max_time)
                   else
                     deadline
                   end
    tms = timeout_ms.nil? ? (@timeout_ms || @client.options.timeout.try(&.total_milliseconds.to_i64)) : timeout_ms

    result = send_run_command(
      name,
      body,
      session,
      read_preference,
      timeout_ms,
      cmd_deadline,
    ) { |reply, cmd_session|
      qr = Commands::RunCommand.cursor_result(reply)
      bind_cursor(Cursor.new(
        @client,
        qr,
        batch_size: batch_size,
        await_time_ms: max_time_ms,
        tailable: tailable,
        session: cmd_session,
        comment: comment,
        timeout_ms: tms,
        timeout_mode: mode,
        deadline: deadline,
      ), cmd_session)
    }
    raise Mongo::Error.new("Command failed to return a result") unless result
    result
  end

  private def send_run_command(name, body, session, read_preference, timeout_ms, deadline, &)
    self.command(
      Commands::RunCommand.new(name),
      command_bson: body,
      session: session,
      read_preference: read_preference,
      timeout_ms: timeout_ms,
      deadline: deadline,
      options: NamedTuple.new,
    ) { |reply, cmd_session|
      yield reply, cmd_session
    }
  end

  # Get a newly allocated `Mongo::Collection` for the collection named *name*.
  def collection(collection : Collection::CollectionKey) : Mongo::Collection
    Collection.new(self, collection)
  end

  # :ditto:
  def [](collection : Collection::CollectionKey) : Mongo::Collection
    self.collection(collection)
  end

  # Runs an aggregation framework pipeline on the database for pipeline stages
  # that do not require an underlying collection, such as $currentOp and $listLocalSessions.
  #
  # NOTE: [for more details, please check the official MongoDB documentation](https://docs.mongodb.com/manual/reference/command/aggregate/).
  def aggregate(
    pipeline : Array,
    *,
    allow_disk_use : Bool? = nil,
    batch_size : Int32? = nil,
    max_time_ms : Int64? = nil,
    bypass_document_validation : Bool? = nil,
    read_concern : ReadConcern? = nil,
    collation : Collation? = nil,
    hint : (String | H)? = nil,
    comment = nil,
    let = nil,
    write_concern : WriteConcern? = nil,
    read_preference : ReadPreference? = nil,
    session : Session::ClientSession? = nil,
    timeout_ms : Int64? = nil,
    timeout_mode : Mongo::TimeoutMode? = nil,
    max_await_time_ms : Int64? = nil,
  ) : Mongo::Cursor? forall H
    hint_value = if hint.nil?
                   nil
                 elsif hint.is_a?(String)
                   hint
                 else
                   BSON.new(hint)
                 end
    Mongo.check_max_await_vs_timeout(max_await_time_ms, timeout_ms || @timeout_ms || @client.options.timeout.try(&.total_milliseconds.to_i64))
    has_timeout = !timeout_ms.nil? || !@timeout_ms.nil? || @client.options.timeout
    if timeout_mode && !has_timeout
      raise Mongo::Error.new("timeoutMode requires timeoutMS")
    end
    mode = timeout_mode || Mongo::TimeoutMode::CursorLifetime
    deadline = unless timeout_ms.nil?
                 Mongo::Deadline.from_timeout_ms(timeout_ms)
               else
                 inherited_deadline
               end
    agg_deadline = mode.iteration? ? deadline.try(&.without_max_time) : deadline
    tms = timeout_ms.nil? ? (@timeout_ms || @client.options.timeout.try(&.total_milliseconds.to_i64)) : timeout_ms
    self.command(Commands::Aggregate, collection: 1, pipeline: pipeline, session: session, deadline: agg_deadline, options: {
      allow_disk_use:             allow_disk_use,
      cursor:                     batch_size.try { {batchSize: batch_size} },
      bypass_document_validation: bypass_document_validation,
      read_concern:               read_concern,
      collation:                  collation,
      hint:                       hint_value,
      comment:                    comment,
      let:                        let.try { BSON.new(let) },
      max_time_ms:                max_time_ms,
      write_concern:              write_concern,
      read_preference:            read_preference,
    }) { |result, cmd_session|
      bind_cursor(Cursor.new(@client, result, batch_size: batch_size, session: cmd_session, comment: comment, timeout_ms: tms, timeout_mode: mode, deadline: deadline), cmd_session)
    }
  end

  # Retrieve information, i.e. the name and options, about the collections and views in a database.
  #
  # Specifically, the command returns a document that contains information with which to create a cursor to the collection information.
  #
  # NOTE: [for more details, please check the official MongoDB documentation](https://docs.mongodb.com/manual/reference/command/listCollections/).
  def list_collections(
    *,
    filter = nil,
    name_only : Bool? = nil,
    authorized_collections : Bool? = nil,
    batch_size : Int32? = nil,
    session : Session::ClientSession? = nil,
    timeout_ms : Int64? = nil,
    timeout_mode : Mongo::TimeoutMode? = nil,
  ) : Mongo::Cursor
    has_timeout = !timeout_ms.nil? || !@timeout_ms.nil? || @client.options.timeout
    if timeout_mode && !has_timeout
      raise Mongo::Error.new("timeoutMode requires timeoutMS")
    end
    cursor_opt = batch_size.try { BSON.new({"batchSize" => batch_size}) }
    result = self.command(Commands::ListCollections, session: session, timeout_ms: timeout_ms, options: {
      filter:                 filter,
      name_only:              name_only,
      authorized_collections: authorized_collections,
      cursor:                 cursor_opt,
    }) { |query_result, cmd_session|
      tms = timeout_ms.nil? ? (@timeout_ms || @client.options.timeout.try(&.total_milliseconds.to_i64)) : timeout_ms
      bind_cursor(Cursor.new(@client, query_result, batch_size: batch_size, session: cmd_session, timeout_ms: tms, timeout_mode: Mongo::TimeoutMode::CursorLifetime), cmd_session)
    }

    raise Mongo::Error.new("Command ListCollections failed to return a result") unless result
    result
  end

  # :nodoc:
  protected def bind_cursor(cursor : Cursor, session : Session::ClientSession?) : Cursor
    cursor.bind(session)
  end

  # Returns a `Mongo::GridFS` instance configured with the arguments provided.
  #
  # NOTE: [for more details about GridFS, please check the official MongoDB manual](https://docs.mongodb.com/manual/core/gridfs/).
  def grid_fs(
    bucket_name : String = "fs",
    *,
    chunk_size_bytes : Int32 = 255 * 1024,
    write_concern : WriteConcern? = nil,
    read_concern : ReadConcern? = nil,
    read_preference : ReadPreference? = nil,
  ) : GridFS::Bucket
    GridFS::Bucket.new(
      self,
      bucket_name: bucket_name,
      chunk_size_bytes: chunk_size_bytes,
      write_concern: write_concern,
      read_concern: read_concern,
      read_preference: read_preference
    )
  end

  # Returns a `ChangeStream::Cursor` watching all the database collection.
  #
  # NOTE: Excludes system collections.
  #
  # ```
  # client = Mongo::Client.new
  # database = client["db"]
  #
  # spawn {
  #   cursor = database.watch(
  #     [
  #       {"$match": {"operationType": "insert"}},
  #     ],
  #     max_await_time_ms: 10000
  #   )
  #   # cursor.of(BSON) converts to the Mongo::ChangeStream::Document(BSON) type.
  #   cursor.of(BSON).each { |doc|
  #     puts doc.to_bson.to_json
  #   }
  # }
  #
  # 100.times do |i|
  #   database["collection"].insert_one({count: i})
  # end
  #
  # sleep
  # ```
  #
  # NOTE: [for more details, please check the official manual](https://docs.mongodb.com/manual/changeStreams/index.html).
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
    tms = timeout_ms.nil? ? (@timeout_ms || @client.options.timeout.try(&.total_milliseconds.to_i64)) : timeout_ms
    Mongo.check_max_await_vs_timeout(max_await_time_ms, tms)
    ChangeStream::Cursor.new(
      client: @client,
      database: name,
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

  # Returns a variety of storage statistics for the database.
  #
  # NOTE: [for more details, please check the official MongoDB documentation](https://docs.mongodb.com/manual/reference/command/dbStats/).
  def stats(*, scale : Int32? = nil) : BSON?
    self.command(Commands::DbStats, options: {scale: scale})
  end
end
