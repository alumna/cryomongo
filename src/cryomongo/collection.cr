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

  # :nodoc:
  def initialize(@database, @name); end

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
    **args,
    &block
  )
    @database.command(
      operation,
      **args,
      collection: @name,
      write_concern: write_concern || @write_concern,
      read_concern: read_concern || @read_concern,
      read_preference: read_preference || @read_preference,
      session: session
    ) { |result|
      yield result
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
    start_at_operation_time : Time? = nil,
    resume_after : BSON? = nil,
    start_after : BSON? = nil,
    max_await_time_ms : Int64? = nil,
    batch_size : Int32? = nil,
    collation : Collation? = nil,
    read_concern : ReadConcern? = nil,
    read_preference : ReadPreference? = nil,
    session : Session::ClientSession? = nil,
  ) : Mongo::ChangeStream::Cursor
    ChangeStream::Cursor.new(
      client: @database.client,
      database: @database.name,
      collection: name,
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

  # Returns a variety of storage statistics for the collection.
  #
  # NOTE: [for more details, please check the official MongoDB documentation](https://docs.mongodb.com/manual/reference/command/collStats/).
  def stats(*, scale : Int32? = nil, session : Session::ClientSession? = nil) : BSON?
    self.command(Commands::CollStats, session: session, options: {scale: scale})
  end
end
