require "openssl"
require "./credentials"
require "./auth"
require "./tls"
require "../compression"

# :nodoc:
# Class so pin, pool, and checkout share one object (generation, serviceId, socket).
class Mongo::Connection
  @@next_connection_id = Atomic(Int64).new(1)

  getter server_description : SDAM::ServerDescription
  getter credentials : Mongo::Credentials
  getter socket : IO
  getter connection_id : Int64
  getter compressor_id : Compression::Id? = nil
  property service_id : BSON::ObjectId? = nil
  # Server hello connectionId. Used in command and heartbeat logs.
  property server_connection_id : Int64? = nil
  # Pool generation at handshake. A later clear with a higher value makes this socket stale.
  property generation : Int32 = 0
  # True after hello succeeds. Handshake errors before this must not clear the pool.
  property handshake_complete : Bool = false
  @sasl_supported_mechs : Array(String)? = nil
  @speculative_scram : Auth::Scram? = nil
  @speculative_x509 : Bool = false
  @speculative_reply : BSON? = nil
  # After the first handshake, later hellos follow helloOk from the server.
  getter? use_hello : Bool = false
  # Monitor sockets must not negotiate SASL mechanisms (SDAM spec).
  @monitor : Bool
  # TCP/UNIX socket under @socket (which may be TLS). Timeouts are set on this fd.
  @raw_socket : ::Socket
  @interrupted = Atomic(Bool).new(false)
  # Pool clear with interruptInUseConnections closed this socket while it was in use.
  @cleared_by_interrupt = Atomic(Bool).new(false)
  # Awaitable hello with exhaustAllowed: the server sends more replies on this socket.
  @more_to_come = false
  # True after a successful send until receive returns. A timeout with this set
  # means the reply has not started; load-balanced killCursors can drain it.
  @awaiting_reply = false
  # Receive timed out with no frame bytes. The next send drains the late reply.
  @pending_reply = false
  # Socket under AwaitReadIO while a CSOT / awaitable-hello deadline is active.
  @deadline_inner : IO? = nil

  def self.next_id : Int64
    @@next_connection_id.add(1)
  end

  # URI connectTimeoutMS / socketTimeoutMS 0 means no timeout.
  # Crystal Time::Span.zero is an immediate timeout on Darwin kqueue.
  def self.uri_timeout(span : Time::Span?) : Time::Span?
    return nil unless span
    return nil if span <= Time::Span.zero
    span
  end

  # Handshake wait. Unset connectTimeoutMS is 10s (URI spec). 0 is infinite.
  # Do not treat unset as infinite: wrap would retry failPoint hello forever
  # and never mark Unknown.
  def self.handshake_timeout(options : Mongo::Options) : Time::Span?
    span = uri_timeout(options.connect_timeout)
    return span if span
    return nil if options.connect_timeout
    10.seconds
  end

  def initialize(@server_description : SDAM::ServerDescription, @credentials : Mongo::Credentials, @options : Mongo::Options, is_monitor : Bool = false, connection_id : Int64? = nil)
    @monitor = is_monitor
    tls_hostname = nil.as(String?)
    if @server_description.address.ends_with? ".sock"
      raw = UNIXSocket.new(@server_description.address)
    else
      # Safely extract host and port, supporting IPv6 bracket notation
      address = @server_description.address
      colon = address.rindex(':')
      if colon && !address.ends_with?(']')
        host = address.byte_slice(0, colon)
        port = address.byte_slice(colon + 1).to_i? || 27017
      else
        host = address
        port = 27017
      end

      # TCPSocket.new and OpenSSL expect IPv6 addresses WITHOUT the brackets
      clean_host = host.starts_with?('[') && host.ends_with?(']') ? host.byte_slice(1, host.bytesize - 2) : host
      tls_hostname = clean_host

      # connectTimeoutMS=0 must be nil. Darwin kqueue treats 0 as now.
      connect_span = Mongo::Connection.uri_timeout(@options.connect_timeout)
      tcp = TCPSocket.new(clean_host, port, dns_timeout: connect_span, connect_timeout: connect_span)
      tcp.tcp_nodelay = true
      raw = tcp
    end
    @raw_socket = raw

    timeout = is_monitor ? @options.connect_timeout : @options.socket_timeout
    timeout = Mongo::Connection.uri_timeout(timeout)

    raw.read_timeout = timeout
    raw.write_timeout = timeout

    socket = raw.as(IO)
    if @options.ssl || @options.tls
      context = OpenSSL::SSL::Context::Client.new
      Mongo::TLS.configure(context, @options)
      context.add_options(OpenSSL::SSL::Options::ALL)
      context.add_options(OpenSSL::SSL::Options.flags(
        NO_SSL_V2,
        NO_COMPRESSION,
        NO_SESSION_RESUMPTION_ON_RENEGOTIATION
      ))
      # Skip hostname check when the URI asked for that, or when TLS is fully insecure.
      # Passing nil hostname tells OpenSSL not to match the certificate name.
      verify_hostname = !(@options.tls_insecure || @options.tls_allow_invalid_hostnames)
      ssl_hostname = verify_hostname ? tls_hostname : nil
      # When hostname is set, OpenSSL uses x509_verify_param_set1_ip_asc for IPs
      # instead of treating a bracketed IP as a DNS name.
      socket = OpenSSL::SSL::Socket::Client.new(raw, context, sync_close: true, hostname: ssl_hostname)
    end

    @socket = socket
    @connection_id = connection_id || @@next_connection_id.add(1)
    @opcode_buf = IO::Memory.new(4096)
    @compressed_buf = IO::Memory.new(4096)
  end

  def handshake(*, send_metadata = false, appname = nil, legacy = false, client_metadata : BSON? = nil, load_balanced : Bool = false)
    # Darwin kqueue fires a 1ms socketTimeoutMS wait at once. Hello then
    # fails before CSOT timeoutMS can ignore socketTimeoutMS (UTF
    # "socketTimeoutMS is ignored if timeoutMS is set"). Slice until
    # connectTimeoutMS (10s if unset) so hello can finish. A failPoint
    # hello block longer than that still times out. Restore socketTimeoutMS
    # after. Do not drop this wrap.
    wrap_connect_deadline do
      run_hello(
        send_metadata: send_metadata,
        appname: appname,
        legacy: legacy,
        client_metadata: client_metadata,
        load_balanced: load_balanced,
        first: true
      )
    end
  end

  # Later monitor / RTT hello. No client metadata. Optional awaitable fields for streaming.
  def hello(*, legacy = false, topology_version : BSON? = nil, max_await_time_ms : Int64? = nil, exhaust_read : Bool = false)
    run_hello(
      legacy: legacy,
      topology_version: topology_version,
      max_await_time_ms: max_await_time_ms,
      first: false,
      exhaust_read: exhaust_read
    )
  end

  private def run_hello(*, send_metadata = false, appname = nil, legacy = false, client_metadata : BSON? = nil, load_balanced : Bool = false, topology_version : BSON? = nil, max_await_time_ms : Int64? = nil, first : Bool = false, exhaust_read : Bool = false)
    # First handshake uses legacy hello unless Server API or load-balanced is set.
    # Later heartbeats use hello when the server sent helloOk: true.
    use_legacy = legacy
    metadata = nil
    if send_metadata
      metadata = client_metadata
      if metadata.nil? && appname
        metadata = Handshake.client_document(appname)
      elsif metadata.nil?
        metadata = Handshake.client_document(nil)
      end
    end
    started = Time.instant
    unless exhaust_read
      body, _ = Commands::Hello.command(
        appname: appname,
        legacy: use_legacy,
        client: metadata,
        load_balanced: load_balanced,
        compression: @options.compressor_list,
        topology_version: topology_version,
        max_await_time_ms: max_await_time_ms
      )

      # Monitor sockets must not send saslSupportedMechs or speculativeAuthenticate (SDAM).
      spec_doc = nil.as(BSON?)
      if first && !@monitor
        spec_doc = start_speculative_auth
      end
      add_sasl = first && !@monitor && @credentials.username && !@credentials.mechanism
      api = @options.server_api
      if add_sasl || api || spec_doc
        body.append do |builder|
          if add_sasl
            source = @credentials.source || ""
            source = "admin" if source.empty?
            builder["saslSupportedMechs"] = "#{source}.#{@credentials.username}"
          end
          if spec_doc
            builder["speculativeAuthenticate"] = spec_doc
          end
          if api
            builder["apiVersion"] = api.version
            builder["apiStrict"] = api.strict.as(Bool) unless api.strict.nil?
            builder["apiDeprecationErrors"] = api.deprecation_errors.as(Bool) unless api.deprecation_errors.nil?
          end
        end
      end

      # Streaming hello (SDAM): exhaustAllowed so the server may send moreToCome.
      flags = if topology_version && max_await_time_ms
                Messages::OpMsg::Flags::ExhaustAllowed
              else
                Messages::OpMsg::Flags::None
              end
      request = Messages::OpMsg.new(body, flag_bits: flags)
      send(request, Commands::Hello, log: false)
    end
    response = if max_await_time_ms || exhaust_read
                 receive_awaitable(started)
               else
                 @more_to_come = false
                 receive(log: false)
               end
    round_trip_time = started.elapsed

    if error = response.error?
      # Fallback to legacy isMaster if 'hello' command is not found (Mongo < 4.4)
      # The Versioned API spec mandates NOT using legacy commands if an API is requested.
      if first && !use_legacy && error.is_a?(Mongo::Error::Command) && error.code == 59 && @options.server_api.nil?
        return handshake(send_metadata: send_metadata, appname: appname, legacy: true, client_metadata: client_metadata, load_balanced: load_balanced)
      end
      raise error
    end

    result = Commands::Hello.result(response.body)

    if result.sasl_supported_mechs
      @sasl_supported_mechs = result.sasl_supported_mechs
    end

    @speculative_reply = result.speculative_authenticate
    if @speculative_reply.nil?
      if spec = response.body["speculativeAuthenticate"]?
        @speculative_reply = spec.as?(BSON)
      end
    end

    @use_hello = !use_legacy || result.helloOk == true
    @compressor_id = Compression.negotiate(@options.compressor_list, result.compression)

    if load_balanced
      sid = result.serviceId
      unless sid
        raise Mongo::Error.new("Driver attempted to initialize in load balancing mode, but the server does not support this mode.")
      end
      @service_id = sid
    end

    {result, round_trip_time}
  end

  def more_to_come? : Bool
    @more_to_come
  end

  # Awaitable hello: wrap the socket so wait-for-data is sliced. A timeout
  # must not unwind Message.new mid-frame (that would drop bytes already read).
  # cancelCheck sets a flag instead of shutdown() on this fd (fd reuse can hit
  # an application socket). Return the first OP_MSG even when moreToCome is set
  # (streaming exhaust). receive() would wait for the next exhaust reply and
  # miss connectTimeoutMS + heartbeatFrequencyMS.
  private def receive_awaitable(started : Time::Instant)
    overall = Mongo::Connection.uri_timeout(@raw_socket.read_timeout)
    expire_at = overall ? started + overall : nil
    # Nested wrap is a no-op. Only unwrap if this call wrapped, or a
    # handshake wrap would be stripped mid-hello.
    wrapped = wrap_deadline_io(expire_at)
    begin
      receive_one
    ensure
      unwrap_deadline_io if wrapped
      apply_timeout(overall)
    end
  end

  # Slice waits until *expire_at*. Nil means no deadline (connectTimeoutMS=0).
  # Returns false when the socket is already wrapped (nested command).
  # *csot* and *leftover_positive_at_wrap* select the leftover-0 last-read
  # (CSOT command sent with leftover >0: two Darwin slices, 20ms Instant,
  # then wait 0). Handshake / Darwin socketTimeoutMS keep the defaults
  # (raise at leftover 0, no last-read).
  def wrap_deadline_io(expire_at : Time::Instant?, *, csot : Bool = false, leftover_positive_at_wrap : Bool = false) : Bool
    return false if @socket.is_a?(AwaitReadIO)
    inner = @socket
    @deadline_inner = inner
    @socket = AwaitReadIO.new(
      inner,
      @raw_socket,
      expire_at,
      self,
      csot: csot,
      leftover_positive_at_wrap: leftover_positive_at_wrap,
    )
    true
  end

  def unwrap_deadline_io : Nil
    inner = @deadline_inner
    return unless inner
    @socket = inner
    @deadline_inner = nil
  end

  # Handshake / SASL: slice until connectTimeoutMS. Unset is 10s, not
  # infinite. Nested wrap is a no-op (already AwaitReadIO). Restore the
  # usual socket timeout after so a later command uses socketTimeoutMS.
  private def wrap_connect_deadline
    connect_span = Mongo::Connection.handshake_timeout(@options)
    expire_at = connect_span ? Time.instant + connect_span : nil
    wrapped = wrap_deadline_io(expire_at)
    begin
      yield
    ensure
      unwrap_deadline_io if wrapped
      restore = @monitor ? connect_span : Mongo::Connection.uri_timeout(@options.socket_timeout)
      apply_timeout(restore)
    end
  end

  private def receive_one
    message = Mongo::Messages::Message.new(socket)
    # Class pointer, not a struct copy. Handshake then calls error? after
    # this Message is gone. A class field on a struct OpMsg is not a
    # Darwin GC root (Wave 47). Receive types are classes (Wave 52).
    # Wave 55: error? walks through OwnedReceive#view (pin.bytes).
    op_msg = message.contents.as(Messages::OpMsg)
    @more_to_come = op_msg.flag_bits.more_to_come?
    op_msg
  end

  def apply_timeout(span : Time::Span?) : Nil
    @raw_socket.read_timeout = span
    @raw_socket.write_timeout = span
    socket = @socket
    return if socket.same?(@raw_socket)
    if socket.responds_to?(:read_timeout=)
      socket.read_timeout = span
    end
    if socket.responds_to?(:write_timeout=)
      socket.write_timeout = span
    end
  end

  # Awaitable hello reads in short slices and checks this flag. A 1ms read
  # timeout wakes Crystal's evented wait. Do not close or shutdown the fd here:
  # cancelCheck runs while application sockets are live (fd reuse).
  def interrupt : Nil
    @interrupted.set(true)
    apply_timeout(1.millisecond) unless @raw_socket.closed?
  end

  # Client#close / monitor stop. interrupt plus shutdown so an awaitable hello
  # blocked on another execution-context thread does not sit out the 100ms slice.
  # Socket#close from this fiber would wait FdLock.
  def interrupt_and_wake : Nil
    interrupt
    raw = @raw_socket
    return if raw.closed?
    LibC.shutdown(raw.fd, LibC::SHUT_RDWR)
  end

  def interrupted_by_clear? : Bool
    @cleared_by_interrupt.get
  end

  # Unblock an in-use command after a monitor timeout. LibC.shutdown wakes a
  # recv on another thread. Socket#close waits for FdLock refs and would stall
  # the monitor until the command fiber finished (the find would succeed).
  def interrupt_in_use : Nil
    @cleared_by_interrupt.set(true)
    interrupt_and_wake
  end

  def self.average_round_trip_time(round_trip_time : Time::Span, old_rtt : Time::Span?)
    # see: https://github.com/mongodb/specifications/blob/master/source/server-selection/server-selection.rst#calculation-of-average-round-trip-times
    if old_rtt
      alpha = 0.2
      (0.2 * round_trip_time.total_milliseconds + (1 - alpha) * old_rtt.total_milliseconds).milliseconds
    else
      round_trip_time
    end
  end

  def authenticate
    # see: https://github.com/mongodb/specifications/blob/master/source/auth/auth.rst#authentication-handshake
    # Darwin 1ms socketTimeoutMS can also fire during SASL after hello.
    # Slice until connectTimeoutMS (10s if unset), same as handshake.
    return if server_description.type.rs_arbiter?
    return if @credentials.username.nil? && @credentials.password.nil? && @credentials.mechanism.nil?

    wrap_connect_deadline do
      if reply = @speculative_reply
        if scram = @speculative_scram
          scram.continue_from_hello(self, reply)
          clear_speculative_auth
          next
        elsif @speculative_x509
          clear_speculative_auth
          next
        end
      end
      clear_speculative_auth

      mechanism = if m = @credentials.mechanism
                    Auth.parse_mechanism(m)
                  elsif mechs = @sasl_supported_mechs
                    if mechs.any? { |name| name.upcase.gsub(/[-_]/, "") == "SCRAMSHA256" }
                      Auth::Mechanism::ScramSha256
                    else
                      Auth::Mechanism::ScramSha1
                    end
                  else
                    Auth::Mechanism::ScramSha1
                  end

      case mechanism
      when .scram_sha1?, .scram_sha256?
        scram = Mongo::Auth::Scram.new(mechanism, @credentials)
        scram.authenticate(self)
      when .mongodb_x509?
        Mongo::Auth::X509.authenticate(self, @credentials)
      when .plain?
        Mongo::Auth::Plain.authenticate(self, @credentials)
      else
        raise Mongo::Error.new "Authentication mechanism not supported: #{mechanism}"
      end
    end
  end

  private def speculative_mechanism : Auth::Mechanism?
    return nil if @monitor
    if m = @credentials.mechanism
      case m.upcase.gsub(/[-_]/, "")
      when "SCRAMSHA1"
        Auth::Mechanism::ScramSha1
      when "SCRAMSHA256"
        Auth::Mechanism::ScramSha256
      when "MONGODBX509"
        Auth::Mechanism::MongodbX509
      else
        nil
      end
    elsif @credentials.username
      Auth::Mechanism::ScramSha256
    end
  end

  private def start_speculative_auth : BSON?
    mech = speculative_mechanism
    return nil unless mech
    case mech
    when .scram_sha1?, .scram_sha256?
      return nil unless @credentials.username
      scram = Auth::Scram.new(mech, @credentials)
      @speculative_scram = scram
      scram.start_document
    when .mongodb_x509?
      @speculative_x509 = true
      Auth::X509.speculative_document(@credentials)
    end
  end

  private def clear_speculative_auth
    @speculative_scram = nil
    @speculative_reply = nil
    @speculative_x509 = false
  end

  def send(op_msg : Messages::OpMsg, command = nil, log = true, &block)
    drain_pending_reply
    message = Messages::Message.new(op_msg)

    Log.debug {
      "(#{server_description.address}) >> #{"[#{message.header.request_id}]".ljust(8)} #{command}"
    } if command && log

    Log.trace {
      "(#{server_description.address}) >> #{"[#{message.header.request_id}]".ljust(8)} Header: #{message.header.inspect}"
    } if log

    Log.trace {
      name = command.responds_to?(:name) ? command.name : ""
      logged = Mongo::Monitoring::Redact.body(name, op_msg.body)
      "(#{server_description.address}) >> #{"[#{message.header.request_id}]".ljust(8)} Body: #{logged.to_json}"
    } if log
    op_msg.each_sequence { |key, contents|
      Log.trace {
        "(#{server_description.address}) >> #{"[#{message.header.request_id}]".ljust(8)} Seq(#{key}): #{contents.to_json}"
      } if log
    }

    yield message

    if (id = @compressor_id) && compress_command?(command)
      write_compressed(message, id)
    else
      message.to_io(socket)
    end
    @awaiting_reply = true
  end

  def send(op_msg : Messages::OpMsg, command = nil, log = true)
    send(op_msg, command, log) { }
  end

  def receive(log = true, &block)
    loop do
      message = Mongo::Messages::Message.new(socket)

      Log.debug {
        "(#{server_description.address}) << #{"[#{message.header.response_to}]".ljust(8)} Header: #{message.header.inspect}"
      } if log

      # Same as receive_one: copy the OpMsg class pointer, then drop Message
      # after the yield. Do not checkin the owned copy. error? uses
      # OwnedReceive#view so the owner stays live (Wave 55).
      op_msg = message.contents.as(Messages::OpMsg)
      more_to_come = op_msg.flag_bits.more_to_come?

      Log.trace {
        "(#{server_description.address}) << #{"[#{message.header.response_to}]".ljust(8)} Body: #{op_msg.body.to_json}"
      } if log
      # Replies of sensitive commands are not printed. Command name is not on the reply path.
      op_msg.each_sequence { |key, contents|
        Log.trace {
          "(#{server_description.address}) << #{"[#{message.header.response_to}]".ljust(8)} Seq(#{key}): #{contents.to_json}"
        }
      } if log

      unless more_to_come
        @awaiting_reply = false
        @pending_reply = false
        yield message
        return op_msg
      end
    end
  end

  def receive(log = false)
    receive(log: log) { }
  end

  def close
    @awaiting_reply = false
    @pending_reply = false
    inner = @socket
    inner.close unless inner.closed?
  rescue
  end

  def awaiting_reply? : Bool
    @awaiting_reply
  end

  def mark_pending_reply : Nil
    @pending_reply = true
    @awaiting_reply = false
  end

  # Read and drop a late reply after a socket timeout so the next command can
  # use this pin (load-balanced killCursors).
  def drain_pending_reply : Nil
    return unless @pending_reply
    @pending_reply = false
    begin
      receive(log: false)
    rescue error
      close
      raise error
    end
  end

  private def compress_command?(command) : Bool
    return false unless command
    name = if command.responds_to?(:name)
             command.name
           elsif command.is_a?(String)
             command
           else
             return false
           end
    !Compression.forbidden?(name)
  end

  # Wrap OP_MSG in OP_COMPRESSED. The inner body has no MsgHeader.
  private def write_compressed(message : Messages::Message, id : Compression::Id) : Nil
    @opcode_buf.clear
    message.contents.to_io(@opcode_buf)
    uncompressed = @opcode_buf.to_slice
    uncompressed_size = uncompressed.size

    @compressed_buf.clear
    level = @options.zlib_compression_level || -1
    Compression.deflate(id, uncompressed, @compressed_buf, level)
    compressed = @compressed_buf.to_slice

    header = Messages::Header.new(
      message_length: 25 + compressed.size,
      request_id: message.header.request_id,
      response_to: message.header.response_to,
      op_code: Messages::OpCode::Compressed
    )
    header.to_io(socket)
    socket.write_bytes(message.header.op_code.value, IO::ByteFormat::LittleEndian)
    socket.write_bytes(uncompressed_size, IO::ByteFormat::LittleEndian)
    socket.write_byte(id.value)
    socket.write(compressed)
    socket.flush
  end

  def interrupted? : Bool
    @interrupted.get
  end
end

require "./io/await_read_io"
