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
  @timeout_ms : Int64? = nil
  @timeout_mode : Mongo::TimeoutMode = Mongo::TimeoutMode::CursorLifetime
  @deadline : Mongo::Deadline? = nil
  # Fresh timeoutMS for one next() when timeoutMode is iteration (change-stream resume uses the same deadline).
  @iteration_deadline : Mongo::Deadline? = nil

  protected property server_description : SDAM::ServerDescription? = nil
  protected property session : Session::ClientSession?
  @pinned_connection : Mongo::Connection? = nil

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
    @timeout_ms : Int64? = nil,
    @timeout_mode : Mongo::TimeoutMode = Mongo::TimeoutMode::CursorLifetime,
    @deadline : Mongo::Deadline? = nil,
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
    @timeout_ms : Int64? = nil,
    @timeout_mode : Mongo::TimeoutMode = Mongo::TimeoutMode::CursorLifetime,
    @deadline : Mongo::Deadline? = nil,
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
    if session
      @pinned_connection = session.take_pending_cursor_connection
    end
    self
  end

  # The server has closed the cursor, or the caller has already received `limit` documents.
  # An open cursor with leftover documents still needs killCursors.
  # :nodoc:
  def exhausted?
    @cursor_id == 0
  end

  # Iterate documents then close the cursor. Prefer this (or a block `find`)
  # over relying on `finalize` to send killCursors.
  def each(&)
    begin
      loop do
        value = self.next
        break if value.is_a?(Iterator::Stop)
        yield value
      end
    ensure
      close
    end
  end

  def next
    owns_iteration = start_iteration_deadline
    begin
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

        # Do not send getMore after this next() leftover is gone.
        check_iteration_expired!
        fetch_more

        # Non-tailable: an empty getMore means the result is exhausted.
        # Tailable / change streams stay open and wait again.
        if !@tailable && batch_empty?
          return Iterator::Stop::INSTANCE
        end

        # Empty tailable getMore: expire this next() instead of looping
        # forever. A getMore with no leftover timeoutMS never returns
        # (ARM sharded hung). Do not start a new timeoutMS per getMore.
        if @tailable && batch_empty?
          check_iteration_expired!
        end
      end
    ensure
      @iteration_deadline = nil if owns_iteration
    end
  end

  # One getMore at most. Returns `nil` when the batch is empty and the cursor is
  # still open (normal for tailable and change-stream cursors).
  def try_next : BSON?
    owns_iteration = start_iteration_deadline
    begin
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
    ensure
      @iteration_deadline = nil if owns_iteration
    end
  end

  # Close the cursor and frees underlying resources.
  # timeout_ms, if set, is the timeout for killCursors only. Otherwise killCursors
  # starts a fresh timeoutMS from the original find/aggregate.
  def close(*, timeout_ms : Int64? = nil)
    conn = @pinned_connection
    if conn && conn.socket.closed?
      # Dead pin: return the socket. Load-balanced killCursors must stay on the
      # same mongos, so do not open a new socket after a network error.
      @pinned_connection = nil
      @client.checkin_connection(conn)
      if @client.options.load_balanced
        @cursor_id = 0_i64
      end
    end
    self.kill(timeout_ms: timeout_ms) unless exhausted?
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

  protected def kill(*, timeout_ms : Int64? = nil)
    return if @cursor_id == 0
    begin
      deadline = unless timeout_ms.nil?
                   Mongo::Deadline.from_timeout_ms(timeout_ms)
                 else
                   kill_deadline
                 end
      @client.command(
        Commands::KillCursors,
        database: @database,
        collection: @collection,
        cursor_ids: [@cursor_id],
        server_description: @server_description,
        session: @session,
        connection: @pinned_connection,
        deadline: deadline
      )
    ensure
      @cursor_id = 0_i64
      release_pin
    end
  end

  protected def end_implicit_session
    if (session = @session) && session.implicit? && !session.fiber_owned?
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
      session: @session,
      connection: @pinned_connection,
      deadline: get_more_deadline
    )

    raise Mongo::Error.new("GetMore command failed to return a result") unless reply

    @cursor_id = reply.cursor.id
    @batch = reply.cursor.next_batch
    @batch_index = 0
    release_pin if @cursor_id == 0

    if (session = @session) && exhausted? && session.implicit? && !session.fiber_owned?
      session.end
    end

    reply
  end

  # timeoutMode iteration: each next/try_next gets a fresh timeoutMS.
  # Change streams set @iteration_deadline first so this returns false.
  private def start_iteration_deadline : Bool
    return false unless @timeout_mode.iteration?
    return false if @timeout_ms.nil?
    return false if @iteration_deadline
    @iteration_deadline = Mongo::Deadline.from_timeout_ms(@timeout_ms)
    true
  end

  # timeoutMode iteration: each next/try_next gets a fresh timeoutMS.
  # AwaitData getMore must use that, not leftover from find.
  # After find (timeoutMS 250, failPoint 150) leftover is ~100ms. A blocked
  # getMore then times out or returns empty and next() sends another getMore
  # (official test: find + one getMore). If leftover is nil, wrap_command_io
  # waits forever and the cell hangs. Do not start a new timeoutMS per
  # getMore inside one next() — that never expires.
  private def get_more_deadline : Mongo::Deadline?
    if @timeout_mode.iteration?
      ms = @timeout_ms
      unless ms.nil?
        d = @iteration_deadline
        if d.nil?
          d = Mongo::Deadline.from_timeout_ms(ms)
          @iteration_deadline = d
        end
        if @tailable && @await_time_ms
          return d
        else
          return d.try(&.without_max_time)
        end
      end
    end
    @deadline
  end

  private def check_iteration_expired! : Nil
    if d = @iteration_deadline || @deadline
      d.check!
    end
  end

  # close() always starts a fresh timeoutMS, even if cursor lifetime already expired.
  private def kill_deadline : Mongo::Deadline?
    if @timeout_ms
      Mongo::Deadline.from_timeout_ms(@timeout_ms)
    else
      @deadline
    end
  end

  private def release_pin : Nil
    conn = @pinned_connection
    return unless conn
    @pinned_connection = nil
    @client.checkin_connection(conn)
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

  # Last-resort cleanup. finalize can run on a GC thread and must not send
  # killCursors or touch the connection pool. Call `#close`, `#each`, or a
  # block `find`. A pinned load-balanced socket is discarded with the cursor;
  # the pool reclaims it when the client closes.
  def finalize
    @cursor_id = 0_i64
    @pinned_connection = nil
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

  def each(&)
    begin
      loop do
        value = self.next
        break if value.is_a?(Iterator::Stop)
        yield value
      end
    ensure
      close
    end
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
