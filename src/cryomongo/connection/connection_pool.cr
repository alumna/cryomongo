require "weak_ref"

# This code is from "crystal/db".

# :nodoc:
class Mongo::Connection::Pool(T)
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
  # indicates if the pool has been cleared
  @closed : Bool = false
  # last time each idle connection was released (keyed by socket object_id)
  @idle_since = Hash(UInt64, Time::Instant).new

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

  # close all resources in the pool
  def close : Nil
    sync do
      @closed = true
      @availability_channel.close
      @total.each &.close
      @total.clear
      @idle.clear
      @idle_since.clear
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

  def checkout : T
    res = sync do
      raise Mongo::Error::PoolCleared.new("Connection pool was cleared") if @closed

      resource = nil

      until resource
        resource = if @idle.empty?
                     if can_increase_pool?
                       @inflight += 1
                       begin
                         unsync { build_resource }
                       ensure
                         @inflight -= 1
                       end
                     else
                       unsync { wait_for_available }
                       raise Mongo::Error::PoolCleared.new("Connection pool was cleared") if @closed
                       pick_available
                     end
                   else
                     pick_available
                   end

        if resource && idle_too_long?(resource)
          discard(resource)
          resource = nil
        end
      end

      if resource
        @idle.delete resource
        forget_idle_time(resource)
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
          if idle_too_long?(resource)
            discard(resource)
            next
          end
          @idle.delete resource
          forget_idle_time(resource)
          resource.before_checkout
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
      @total.delete(resource)
      @idle.delete(resource)
      forget_idle_time(resource)
    end
  end

  def release(resource : T) : Nil
    sync do
      if @closed
        resource.close
        @total.delete(resource)
        forget_idle_time(resource)
        return
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
      else
        resource.close
        @total.delete(resource)
        forget_idle_time(resource)
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
    @idle.includes?(resource)
  end

  # :nodoc:
  def delete(resource : T)
    @total.delete(resource)
    @idle.delete(resource)
    forget_idle_time(resource)
  end

  private def build_resource : T
    resource = @factory.call
    @total << resource
    @idle << resource
    mark_idle(resource)
    resource
  end

  # Connection is a struct. The socket object is the stable identity.
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
    @idle.delete(resource)
    @total.delete(resource)
    forget_idle_time(resource)
    resource.close
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

  private def wait_for_available
    select
    when @availability_channel.receive
    when timeout(@checkout_timeout.seconds)
      raise Mongo::Error::Connection.new("Too many open connections, could not check out a connection in #{@checkout_timeout} seconds.")
    end
  rescue Channel::ClosedError
    raise Mongo::Error::PoolCleared.new("Connection pool was cleared")
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
