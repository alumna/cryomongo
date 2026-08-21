require "weak_ref"

# This code is from "crystal/db".

# :nodoc:
class Mongo::Connection::Pool(T)
  # Why a checked-out socket is held. Wait-queue timeout lists these counts.
  enum InUse
    Other
    Cursor
    Transaction
  end

  # Pool configuration

  # initial number of connections in the pool
  @initial_pool_size : Int32
  # maximum amount of connections in the pool (Idle + InUse)
  @max_pool_size : Int32
  # maximum amount of idle connections in the pool
  @max_idle_pool_size : Int32
  # seconds to wait before timeout while doing a checkout
  @checkout_timeout : Float64
  # close an idle connection after this time (maxIdleTimeMS)
  @max_idle_time : Time::Span?

  # Pool state

  # total of open connections managed by this pool
  @total = [] of T
  # connections available for checkout
  @idle = Set(T).new
  # connections waiting to be stablished (they are not in *@idle* nor in *@total*)
  @inflight : Int32
  # CMAP: paused until a monitor check marks the pool ready. Closed is terminal.
  @paused : Bool = true
  @closed : Bool = false
  # One background fiber fills minPoolSize after ready.
  @populate_running : Bool = false
  # last time each idle connection was released (keyed by socket object_id)
  @idle_since = Hash(UInt64, Time::Instant).new
  # Non-load-balanced generation. Incremented on a full pool clear.
  @generation : Int32 = 0
  # Load-balanced: generation per mongos serviceId.
  @service_generations = Hash(BSON::ObjectId, Int32).new
  # Load-balanced: open sockets per serviceId. Entry is removed at 0.
  @service_counts = Hash(BSON::ObjectId, Int32).new
  # Checked-out purpose, keyed by connection_id (Connection is a struct).
  @in_use = Hash(Int64, InUse).new

  # Sync state

  # communicate that a connection is available for checkout
  @availability_channel : Channel(Nil)
  # global pool mutex
  @mutex : Sync::Mutex

  def initialize(@initial_pool_size = 1, @max_pool_size = 0, @max_idle_pool_size = 1, @checkout_timeout = 5.0,
                 @max_idle_time : Time::Span? = nil,
                 &@factory : -> T)
    @availability_channel = Channel(Nil).new
    @inflight = 0
    @mutex = Sync::Mutex.new

    @initial_pool_size.times { build_resource }
  end

  # True after close().
  def closed? : Bool
    sync { @closed }
  end

  # CMAP paused: minPoolSize fill must not run. Checkout still works (Phase 3.5 will reject it).
  def paused? : Bool
    sync { @paused }
  end

  # Transition paused -> ready. Returns true when this call made the change (emit PoolReadyEvent).
  def mark_ready : Bool
    sync do
      return false if @closed
      return false unless @paused
      @paused = false
      true
    end
  end

  # Fill idle sockets up to minPoolSize in a background fiber. Handshake I/O does
  # not hold the pool mutex. Stops when paused, closed, or a populate error runs.
  def start_min_size(n : Int32, &on_error : Exception ->) : Nil
    return if n <= 0
    sync do
      return if @closed || @paused || @populate_running
      @populate_running = true
    end
    spawn do
      populate_min(n, &on_error)
    ensure
      sync { @populate_running = false }
    end
  end

  # close all resources in the pool
  def close : Nil
    sync do
      @closed = true
      @paused = true
      @availability_channel.close
      @total.each &.close
      @total.clear
      @idle.clear
      @idle_since.clear
      @in_use.clear
      @service_generations.clear
      @service_counts.clear
    end
  end

  record Stats,
    open_connections : Int32,
    idle_connections : Int32,
    in_flight_connections : Int32,
    max_connections : Int32

  # Returns stats of the pool
  def stats
    Stats.new(
      open_connections: @total.size,
      idle_connections: @idle.size,
      in_flight_connections: @inflight,
      max_connections: @max_pool_size,
    )
  end

  # Sockets currently checked out, including pins.
  def checked_out_count : Int32
    sync { @total.size - @idle.size }
  end

  def stale?(resource : T) : Bool
    sync { stale_unlocked?(resource) }
  end

  def mark_cursor(resource : T) : Nil
    sync { @in_use[resource.connection_id] = InUse::Cursor }
  end

  def mark_transaction(resource : T) : Nil
    sync { @in_use[resource.connection_id] = InUse::Transaction }
  end

  # Increment generation. Idle sockets stay until checkin/checkout (CMAP lazy close).
  # Load-balanced: pass service_id so other mongos sockets stay.
  # Waiters on a full clear (no service_id) get PoolClearedError. The pool stays open.
  def clear(service_id : BSON::ObjectId? = nil) : Array(T)
    sync do
      if sid = service_id
        @service_generations[sid] = (@service_generations[sid]? || 0) + 1
      else
        @generation += 1
        # Full clear: stop minPoolSize fill until the next ready().
        @paused = true
      end
      # Wake waiters. They see the new generation (or a closed channel) and
      # raise PoolCleared instead of waiting for the dead socket.
      old = @availability_channel
      @availability_channel = Channel(Nil).new
      old.close
    end
    [] of T
  end

  def checkout(wait : Time::Span? = nil) : T
    res = sync do
      raise Mongo::Error::PoolCleared.new("Connection pool was cleared") if @closed
      start_gen = @generation

      resource = nil

      until resource
        raise Mongo::Error::PoolCleared.new("Connection pool was cleared") if @closed
        resource = if @idle.empty?
                     if can_increase_pool?
                       @inflight += 1
                       begin
                         created = unsync { @factory.call }
                         created.generation = generation_for(created.service_id)
                         add_service_count(created.service_id)
                         @total << created
                         created
                       ensure
                         @inflight -= 1
                       end
                     else
                       # Full clear while waiting: CMAP waiters get PoolClearedError.
                       if @generation != start_gen
                         raise Mongo::Error::PoolCleared.new("Connection pool was cleared")
                       end
                       timed_out = false
                       unsync { timed_out = !wait_for_available(wait) }
                       raise Mongo::Error::PoolCleared.new("Connection pool was cleared") if @closed
                       if @generation != start_gen
                         raise Mongo::Error::PoolCleared.new("Connection pool was cleared")
                       end
                       raise wait_queue_error if timed_out
                       pick_available
                     end
                   else
                     pick_available
                   end

        if resource && (idle_too_long?(resource) || stale_unlocked?(resource))
          discard(resource)
          resource = nil
        end
      end

      if resource
        delete_idle(resource)
        forget_idle_time(resource)
        @in_use[resource.connection_id] = InUse::Other
      end

      resource
    end

    if res.responds_to?(:before_checkout)
      res.before_checkout
    end
    res
  end

  def checkout(&block : T ->)
    connection = checkout

    begin
      yield connection
    ensure
      release connection
    end
  end

  # ```
  # selected, is_candidate = pool.checkout_some(candidates)
  # ```
  # `selected` be a resource from the `candidates` list and `is_candidate` == `true`
  # or `selected` will be a new resource and `is_candidate` == `false`
  def checkout_some(candidates : Enumerable(WeakRef(T))) : {T, Bool}
    sync do
      raise Mongo::Error::PoolCleared.new("Connection pool was cleared") if @closed

      candidates.each do |ref|
        resource = ref.value
        if resource && is_available?(resource)
          if idle_too_long?(resource) || stale_unlocked?(resource)
            discard(resource)
            next
          end
          delete_idle(resource)
          forget_idle_time(resource)
          @in_use[resource.connection_id] = InUse::Other
          resource.before_checkout if resource.responds_to?(:before_checkout)
          return {resource, true}
        end
      end
    end

    resource = checkout
    {resource, candidates.any? { |ref| ref.value == resource }}
  end

  # Remove a checked-out connection that can no longer be used (dead socket).
  def drop(resource : T) : Nil
    sync do
      resource.close
      remove(resource)
      signal_available
    end
  end

  # Return a socket to the pool, or close it if it is dead, stale, or the pool is closed.
  # Returns "stale", "error", "poolClosed", or nil when the socket is idle again.
  def release(resource : T) : String?
    sync do
      @in_use.delete(resource.connection_id)
      if @closed
        resource.close
        remove(resource)
        return "poolClosed"
      end

      if resource.socket.closed?
        remove(resource)
        signal_available
        return "error"
      end

      if stale_unlocked?(resource)
        resource.close
        remove(resource)
        signal_available
        return "stale"
      end

      if can_increase_idle_pool
        @idle << resource
        mark_idle(resource)
        if resource.responds_to?(:after_release)
          resource.after_release
        end
        select
        when @availability_channel.send nil
          # send if someone is waiting…
        else
          # …but do not block.
        end
        nil
      else
        resource.close
        remove(resource)
        "idle"
      end
    end
  end

  # :nodoc:
  def each_resource(&)
    sync do
      @idle.each do |resource|
        yield resource
      end
    end
  end

  # :nodoc:
  def is_available?(resource : T)
    @idle.any? { |c| c.connection_id == resource.connection_id }
  end

  # :nodoc:
  def delete(resource : T)
    remove(resource)
  end

  private def build_resource : T
    resource = @factory.call
    resource.generation = generation_for(resource.service_id)
    add_service_count(resource.service_id)
    @total << resource
    @idle << resource
    mark_idle(resource)
    resource
  end

  private def generation_for(service_id : BSON::ObjectId?) : Int32
    if sid = service_id
      @service_generations[sid]? || 0
    else
      @generation
    end
  end

  private def stale_unlocked?(resource : T) : Bool
    resource.generation != generation_for(resource.service_id)
  end

  private def add_service_count(service_id : BSON::ObjectId?) : Nil
    return unless sid = service_id
    @service_counts[sid] = (@service_counts[sid]? || 0) + 1
  end

  private def drop_service_count(service_id : BSON::ObjectId?) : Nil
    return unless sid = service_id
    n = (@service_counts[sid]? || 1) - 1
    if n <= 0
      @service_counts.delete(sid)
      @service_generations.delete(sid)
    else
      @service_counts[sid] = n
    end
  end

  private def wait_queue_error : Mongo::Error::Connection
    cursors = 0
    txns = 0
    other = 0
    @in_use.each_value do |kind|
      case kind
      when .cursor?
        cursors += 1
      when .transaction?
        txns += 1
      else
        other += 1
      end
    end
    Mongo::Error::Connection.new(
      "Timeout waiting for connection from the connection pool. maxPoolSize: #{@max_pool_size}, connections in use by cursors: #{cursors}, connections in use by transactions: #{txns}, connections in use by other operations: #{other}"
    )
  end

  private def same_id?(left : T, right : T) : Bool
    left.connection_id == right.connection_id
  end

  private def delete_idle(resource : T) : Nil
    @idle.reject! { |c| same_id?(c, resource) }
  end

  private def remove(resource : T) : Nil
    @total.reject! { |c| same_id?(c, resource) }
    delete_idle(resource)
    forget_idle_time(resource)
    @in_use.delete(resource.connection_id)
    drop_service_count(resource.service_id)
  end

  private def idle_key(resource : T) : UInt64
    resource.socket.object_id
  end

  private def mark_idle(resource : T)
    @idle_since[idle_key(resource)] = Time.instant
  end

  private def forget_idle_time(resource : T)
    @idle_since.delete(idle_key(resource))
  end

  private def idle_too_long?(resource : T) : Bool
    max = @max_idle_time
    return false unless max
    if since = @idle_since[idle_key(resource)]?
      since.elapsed > max
    else
      false
    end
  end

  private def discard(resource : T)
    resource.close
    remove(resource)
    signal_available
  end

  # Wake one waiter without blocking. Used when a slot is freed (dead / stale).
  private def signal_available : Nil
    select
    when @availability_channel.send nil
    else
    end
  end

  private def populate_min(n : Int32, &on_error : Exception ->) : Nil
    limit = n
    if @max_pool_size > 0 && limit > @max_pool_size
      limit = @max_pool_size
    end
    loop do
      started = sync do
        if @closed || @paused || @total.size + @inflight >= limit || !can_increase_pool?
          false
        else
          @inflight += 1
          true
        end
      end
      break unless started
      created = nil.as(T?)
      begin
        created = @factory.call
      rescue error
        sync { @inflight -= 1 }
        on_error.call(error)
        break
      end
      keep = false
      sync do
        @inflight -= 1
        if created_conn = created
          if @closed || @paused
            created_conn.close
          else
            created_conn.generation = generation_for(created_conn.service_id)
            add_service_count(created_conn.service_id)
            @total << created_conn
            @idle << created_conn
            mark_idle(created_conn)
            keep = true
          end
        end
      end
      signal_available if keep
    end
  end

  private def can_increase_pool?
    @max_pool_size == 0 || @total.size + @inflight < @max_pool_size
  end

  private def can_increase_idle_pool
    @idle.size < @max_idle_pool_size
  end

  private def pick_available
    @idle.first?
  end

  # True when a socket became free. False on wait-queue timeout.
  private def wait_for_available(wait : Time::Span? = nil) : Bool
    span = wait || @checkout_timeout.seconds
    span = Time::Span.zero if span < Time::Span.zero
    select
    when @availability_channel.receive
      true
    when timeout(span)
      false
    end
  rescue Channel::ClosedError
    true
  end

  private def sync(&)
    @mutex.lock
    begin
      yield
    ensure
      @mutex.unlock
    end
  end

  private def unsync(&)
    @mutex.unlock
    begin
      yield
    ensure
      @mutex.lock
    end
  end
end
