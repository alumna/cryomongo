require "bson"
require "./commands"

# A `Cursor` is a pointer to the result set of a query.
#
# This class implements the [`Iterator`](https://crystal-lang.org/api/Iterator.html) module under the hood.
#
# ```
# # Find is one of the methods that return a cursor.
# cursor = collection.find({qty: {"$gt": 20}})
# # Using `to_a` iterates the cursor until the end and stores the elements inside an `Array`.
# elements = cursor.to_a
# # `to_a` is one of the methods inherited from the `Iterator` module.
# ```
class Mongo::Cursor
  include Iterator(BSON)

  @database : String
  @collection : Collection::CollectionKey
  @tailable : Bool = false
  # Documents already returned to the caller. Used to honor `limit`.
  @yielded : Int32 = 0
  # Index into @batch. Avoid Array#shift? (O(n) per document).
  @batch_index : Int32 = 0
  @limit : Int32? = nil
  @comment : BSON::Value? = nil

  protected property server_description : SDAM::ServerDescription? = nil
  protected property session : Session::ClientSession?

  # :nodoc:
  def initialize(
    @client : Mongo::Client,
    @cursor_id : Int64,
    namespace : String,
    @batch : Array(BSON),
    @batch_size : Int32? = nil,
    @limit : Int32? = nil,
    @await_time_ms : Int64? = nil,
    @tailable : Bool = false,
    @session : Session::ClientSession? = nil,
    @comment = nil,
  )
    @database, @collection = namespace.split(".", 2)
  end

  # :nodoc:
  def initialize(
    @client : Mongo::Client,
    result : Commands::Common::QueryResult,
    @batch_size : Int32? = nil,
    @limit : Int32? = nil,
    @await_time_ms : Int64? = nil,
    @tailable : Bool = false,
    @session : Session::ClientSession? = nil,
    @comment = nil,
  )
    @cursor_id = result.cursor.id
    @batch = result.cursor.first_batch
    @database, @collection = result.cursor.ns.split(".", 2)
  end

  # Copy the session and originating server onto this cursor.
  # getMore and killCursors must use the same lsid and the same server.
  protected def bind(session : Session::ClientSession?) : self
    @session = session
    @server_description = session.try(&.last_operation_server)
    self
  end

  # The server has closed the cursor, or the caller has already received `limit` documents.
  # An open cursor with leftover documents still needs killCursors.
  # :nodoc:
  def exhausted?
    @cursor_id == 0
  end

  def next
    loop do
      if (limit = @limit) && @yielded >= limit
        return Iterator::Stop::INSTANCE
      end

      if element = next_from_batch
        @yielded += 1
        return element
      end

      # Tailable / awaitData / change streams stay open on an empty getMore.
      # Only a closed cursor (id 0) means the iteration is over.
      return Iterator::Stop::INSTANCE if @cursor_id == 0

      fetch_more

      # Non-tailable: an empty getMore means the result is exhausted.
      # Tailable / change streams stay open and wait again.
      if !@tailable && batch_empty?
        return Iterator::Stop::INSTANCE
      end
    end
  end

  # One getMore at most. Returns `nil` when the batch is empty and the cursor is
  # still open (normal for tailable and change-stream cursors).
  def try_next : BSON?
    return nil if (limit = @limit) && @yielded >= limit

    if element = next_from_batch
      @yielded += 1
      return element
    end

    return nil if @cursor_id == 0

    fetch_more

    if element = next_from_batch
      @yielded += 1
      return element
    end

    nil
  end

  # Close the cursor and frees underlying resources.
  def close
    unless exhausted?
      self.kill
    end
  rescue e
    # Ignore - client might be dead
  ensure
    end_implicit_session
  end

  # Kill the cursor on the pinned server only. Errors are ignored (resume path).
  protected def kill_quietly
    return if @cursor_id == 0
    self.kill
  rescue
    @cursor_id = 0_i64
    @batch = [] of BSON
    @batch_index = 0
  end

  private def next_from_batch : BSON?
    return nil if @batch_index >= @batch.size
    element = @batch[@batch_index]
    @batch_index += 1
    element
  end

  private def batch_empty? : Bool
    @batch_index >= @batch.size
  end

  # True after the caller has taken the last document in the current batch.
  # Change streams use this for the last-document PBRT rule.
  protected def batch_consumed? : Bool
    @batch_index >= @batch.size
  end

  protected def kill
    return if @cursor_id == 0
    @client.command(
      Commands::KillCursors,
      database: @database,
      collection: @collection,
      cursor_ids: [@cursor_id],
      server_description: @server_description,
      session: @session
    )
    @cursor_id = 0_i64
  end

  protected def end_implicit_session
    if (session = @session) && session.implicit?
      session.end
    end
  end

  protected def fetch_more
    return if @cursor_id == 0

    batch_size = next_batch_size

    reply = @client.command(
      Commands::GetMore,
      database: @database,
      collection: @collection,
      cursor_id: @cursor_id,
      batch_size: batch_size,
      max_time_ms: @await_time_ms,
      comment: @comment,
      server_description: @server_description,
      session: @session
    )

    raise Mongo::Error.new("GetMore command failed to return a result") unless reply

    @cursor_id = reply.cursor.id
    @batch = reply.cursor.next_batch
    @batch_index = 0

    if (session = @session) && exhausted? && session.implicit?
      session.end
    end

    reply
  end

  # Prefer the original batchSize. 0 means "default" (omit on getMore).
  # When a limit remains, never ask for more documents than the caller still wants.
  private def next_batch_size : Int32?
    if (limit = @limit)
      remaining = limit - @yielded
      return nil if remaining <= 0
      if (bs = @batch_size) && bs > 0 && bs < remaining
        bs
      else
        remaining
      end
    else
      bs = @batch_size
      (bs && bs > 0) ? bs : nil
    end
  end

  # Will convert the elements to the `T` type while iterating the `Cursor`.
  #
  # Assumes that `T` has a constructor method named `from_bson` that takes a single `BSON` argument.
  #
  # ```
  # # Using .of is shorter than…
  # wrapped_cursor = cursor.of(Type)
  # # …having to .map and initialize.
  # wrapped_cursor = cursor.map { |element| Type.from_bson(element) }
  # ```
  #
  # NOTE: Internally, wraps the cursor inside a `Mongo::Cursor::Wrapper` with type `T`.
  def of(type : T) forall T
    {% begin %}
    Cursor::Wrapper({{T.instance}}).new(self)
    {% end %}
  end

  # Last-resort cleanup. finalize can run on a GC thread and must not be
  # the only way to send killCursors. Call `#close` (or iterate to the end).
  def finalize
    close
  end
end

# A wrapper that will try to convert elements to the underlying `T` type while iterating the `Cursor`.
#
# Assumes that `T` has a constructor method named `from_bson`.
class Mongo::Cursor::Wrapper(T)
  include Iterator(T)

  # :nodoc:
  def initialize(@cursor : Cursor)
  end

  def next
    if (elt = @cursor.next).is_a? Iterator::Stop
      elt
    else
      {% if T == BSON %}
        elt
      {% else %}
        T.from_bson elt
      {% end %}
    end
  end

  delegate :close, to: @cursor
end
