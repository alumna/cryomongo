require "./client"
require "./database"
require "./cursor"
require "./bulk"
require "./tools"
require "./concerns"
require "./read_preference"
require "./collation"
require "./index"
require "./change_stream"
require "./collection/*"

# A `Collection` provides access to a MongoDB collection.
#
# ```
# collection = client["database_name"]["collection_name"]
# ```
class Mongo::Collection
  include WithReadConcern
  include WithWriteConcern
  include WithReadPreference

  # A collection name can be a String or an Integer.
  alias CollectionKey = String | Int32

  # The parent database.
  getter database : Mongo::Database
  # The collection name.
  getter name : CollectionKey
  # CSOT timeoutMS for this collection. Nil inherits from the database.
  property timeout_ms : Int64? = nil

  # :nodoc:
  def initialize(@database, @name); end

  # Deadline from timeoutMS on this collection, database, or client.
  def inherited_deadline : Mongo::Deadline?
    if ms = @timeout_ms
      Mongo::Deadline.from_timeout_ms(ms)
    else
      @database.inherited_deadline
    end
  end

  # Execute a command on the server targeting the collection.
  #
  # Will automatically set the *collection* and *database* arguments.
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
    @database.command(
      operation,
      **args,
      collection: @name,
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
    ) { |result| result }
  end

  # :nodoc:
  protected def bind_cursor(cursor : Cursor, session : Session::ClientSession?) : Cursor
    cursor.bind(session)
  end

  protected def resolved_timeout_ms(timeout_ms : Int64?) : Int64?
    return timeout_ms unless timeout_ms.nil?
    return @timeout_ms unless @timeout_ms.nil?
    return @database.timeout_ms unless @database.timeout_ms.nil?
    @database.client.options.timeout.try(&.total_milliseconds.to_i64)
  end

  protected def check_max_await_vs_timeout(max_await_time_ms : Int64?, timeout_ms : Int64?) : Nil
    Mongo.check_max_await_vs_timeout(max_await_time_ms, resolved_timeout_ms(timeout_ms))
  end

  # Returns a `ChangeStream::Cursor` watching a specific collection.
  #
  # ```
  # client = Mongo::Client.new
  # collection = client["db"]["coll"]
  #
  # spawn {
  #   cursor = collection.watch(
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
  #   collection.insert_one({count: i})
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
    start_at_operation_time : Time? = nil,
    resume_after : BSON? = nil,
    start_after : BSON? = nil,
    max_await_time_ms : Int64? = nil,
    batch_size : Int32? = nil,
    collation : Collation? = nil,
    read_concern : ReadConcern? = nil,
    read_preference : ReadPreference? = nil,
    comment = nil,
    session : Session::ClientSession? = nil,
    timeout_ms : Int64? = nil,
  ) : Mongo::ChangeStream::Cursor
    check_max_await_vs_timeout(max_await_time_ms, timeout_ms)
    ChangeStream::Cursor.new(
      client: @database.client,
      database: @database.name,
      collection: name,
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
      timeout_ms: resolved_timeout_ms(timeout_ms)
    )
  end

  # Drops this collection. NamespaceNotFound (code 26) is ignored.
  #
  # NOTE: [for more details, please check the official MongoDB documentation](https://docs.mongodb.com/manual/reference/command/drop/).
  def drop(*, session : Session::ClientSession? = nil, timeout_ms : Int64? = nil, deadline : Mongo::Deadline? = nil) : Commands::Common::BaseResult?
    @database.command(Commands::Drop, name: @name, session: session, timeout_ms: timeout_ms, deadline: deadline, write_concern: @write_concern)
  rescue e : Mongo::Error::Command
    return nil if e.code == 26
    raise e
  end

  # Returns a variety of storage statistics for the collection.
  #
  # NOTE: [for more details, please check the official MongoDB documentation](https://docs.mongodb.com/manual/reference/command/collStats/).
  def stats(*, scale : Int32? = nil, session : Session::ClientSession? = nil) : BSON?
    self.command(Commands::CollStats, session: session, options: {scale: scale})
  end
end
