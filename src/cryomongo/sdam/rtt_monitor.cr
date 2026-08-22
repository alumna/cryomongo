require "wait_group"

# Dedicated hello connection used only while streaming. Errors here do not mark
# the server Unknown (the monitor thread owns topology). Same appname so
# failCommand on hello can hit this socket as well as the monitor socket.
# Do not emit ServerHeartbeat* events (SDAM spec: RTT commands are silent).
# :nodoc:
class Mongo::SDAM::RttMonitor
  @lock = Sync::Mutex.new
  @average : Time::Span? = nil
  @samples = Array(Time::Span).new(10)
  @connection : Mongo::Connection? = nil
  @closed = Atomic(Bool).new(false)
  @started = Atomic(Bool).new(false)
  @wake = Channel(Nil).new(1)
  @done = WaitGroup.new

  def initialize(
    @client : Mongo::Client,
    @address : String,
    @credentials : Mongo::Credentials,
    @heartbeat_frequency : Time::Span,
  )
  end

  def start : Nil
    return unless @started.compare_and_set(false, true)
    @done.add(1)
    spawn { run }
  end

  def started? : Bool
    @started.get
  end

  def close : Nil
    @closed.set(true)
    select
    when @wake.send(nil)
    else
    end
    @wake.close rescue nil
    @done.wait if @started.get
  end

  def reset : Nil
    @lock.synchronize do
      @average = nil
      @samples.clear
    end
  end

  def add_sample(sample : Time::Span) : Nil
    @lock.synchronize do
      @average = Mongo::Connection.average_round_trip_time(sample, @average)
      @samples << sample
      @samples.shift if @samples.size > 10
    end
  end

  def average : Time::Span
    @lock.synchronize { @average || Time::Span.zero }
  end

  def copy_window_into(description : ServerDescription) : Nil
    @lock.synchronize do
      description.round_trip_time = @average || Time::Span.zero
      description.replace_rtt_window(@samples)
    end
  end

  private def run
    loop do
      break if @closed.get
      begin
        add_sample(ping)
      rescue
        drop_socket(close_socket: true)
      end
      break if @closed.get
      begin
        select
        when @wake.receive
        when timeout @heartbeat_frequency
        end
      rescue Channel::ClosedError
        break
      end
    end
  ensure
    drop_socket(close_socket: true)
    @done.done
  end

  private def ping : Time::Span
    conn = @connection
    if conn.nil? || conn.socket.closed?
      drop_socket(close_socket: true)
      conn = open_connection
      @connection = conn
      legacy = @client.options.server_api.nil?
      _, rtt = conn.handshake(
        send_metadata: true,
        appname: @client.options.appname,
        legacy: legacy,
        client_metadata: @client.handshake_client_document
      )
      return rtt
    end
    _, rtt = conn.hello(legacy: !conn.use_hello?)
    rtt
  end

  private def open_connection : Mongo::Connection
    Mongo::Connection.new(ServerDescription.new(@address), @credentials, @client.options, is_monitor: true)
  end

  private def drop_socket(*, close_socket : Bool = true) : Nil
    conn = @lock.synchronize do
      c = @connection
      @connection = nil
      c
    end
    return unless conn
    conn.interrupt
    conn.close rescue nil if close_socket
  end
end
