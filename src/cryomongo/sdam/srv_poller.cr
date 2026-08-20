require "wait_group"

# Background DNS rescan for mongodb+srv://. Adds and removes mongos hosts.
# Only runs while the topology is Sharded or Unknown. Never runs in load-balanced mode.
class Mongo::SDAM::SrvPoller
  @closed : Bool = false
  @done = WaitGroup.new
  @wakeup = Channel(Nil).new(1)
  @lock = Sync::Mutex.new
  @interval : Time::Span = 60.seconds

  def initialize(
    @client : Mongo::Client,
    @hostname : String,
    @service_name : String,
    @heartbeat_frequency : Time::Span,
    @srv_max_hosts : Int32,
  )
  end

  def start : Nil
    @done.add(1)
    spawn { scan_loop }
  end

  def close : Nil
    @lock.synchronize { @closed = true }
    select
    when @wakeup.send(nil)
    else
    end
  end

  def wait_closed : Nil
    @done.wait
  end

  private def scan_loop
    srv = Mongo::SRV.new(@hostname, @service_name)
    loop do
      break if closed?
      sleep_interval
      break if closed?
      rescan(srv)
    end
  ensure
    @done.done
  end

  private def closed? : Bool
    @lock.synchronize { @closed }
  end

  private def sleep_interval : Nil
    remaining = @lock.synchronize { @interval }
    select
    when @wakeup.receive
    when timeout remaining
    end
  end

  private def rescan(srv : Mongo::SRV) : Nil
    topology = @client.topology
    unless topology.type.sharded? || topology.type.unknown?
      return
    end
    if @client.options.load_balanced
      return
    end

    hosts, min_ttl = srv.poll
    if hosts.empty?
      @lock.synchronize { @interval = @heartbeat_frequency }
      Mongo::Log.warn { "SRV poll for #{@hostname} returned no hosts; retrying in #{@heartbeat_frequency}" }
      return
    end

    @lock.synchronize { @interval = min_ttl }
    @client.apply_srv_hosts(hosts.map(&.address), @srv_max_hosts)
  rescue e
    Mongo::Log.warn { "SRV poll error for #{@hostname}: #{e}" }
    @lock.synchronize { @interval = @heartbeat_frequency }
  end
end
