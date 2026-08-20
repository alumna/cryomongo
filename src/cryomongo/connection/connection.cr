require "openssl"
require "./credentials"
require "./auth"

# :nodoc:
struct Mongo::Connection
  @@next_connection_id = Atomic(Int64).new(1)

  getter server_description : SDAM::ServerDescription
  getter credentials : Mongo::Credentials
  getter socket : IO
  getter connection_id : Int64
  getter service_id : BSON::ObjectId? = nil
  @sasl_supported_mechs : Array(String)? = nil
  # After the first handshake, later hellos follow helloOk from the server.
  getter? use_hello : Bool = false

  def initialize(@server_description : SDAM::ServerDescription, @credentials : Mongo::Credentials, @options : Mongo::Options, is_monitor : Bool = false)
    if @server_description.address.ends_with? ".sock"
      socket = UNIXSocket.new(@server_description.address)
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

      socket = TCPSocket.new(clean_host, port, dns_timeout: @options.connect_timeout, connect_timeout: @options.connect_timeout)
      socket.tcp_nodelay = true
    end

    timeout = is_monitor ? @options.connect_timeout : @options.socket_timeout

    if timeout && timeout.total_milliseconds == 0
      timeout = nil
    end

    socket.read_timeout = timeout
    socket.write_timeout = timeout

    if @options.ssl || @options.tls
      context = OpenSSL::SSL::Context::Client.new
      if tls_ca_file = @options.tls_ca_file
        context.ca_certificates = tls_ca_file
      end
      if tls_certificate_key_file = @options.tls_certificate_key_file
        context.certificate_chain = tls_certificate_key_file
        context.private_key = tls_certificate_key_file
      end

      if @options.tls_insecure || @options.tls_allow_invalid_certificates
        context.verify_mode = OpenSSL::SSL::VerifyMode::NONE
      end
      context.add_options(OpenSSL::SSL::Options::ALL)
      context.add_options(OpenSSL::SSL::Options.flags(
        NO_SSL_V2,
        NO_COMPRESSION,
        NO_SESSION_RESUMPTION_ON_RENEGOTIATION
      ))
      # Skip hostname check when the URI asked for that, or when TLS is fully insecure.
      # Passing nil hostname tells OpenSSL not to match the certificate name.
      verify_hostname = !(@options.tls_insecure || @options.tls_allow_invalid_hostnames)
      tls_hostname = verify_hostname ? clean_host : nil
      # When hostname is set, OpenSSL uses x509_verify_param_set1_ip_asc for IPs
      # instead of treating a bracketed IP as a DNS name.
      socket = OpenSSL::SSL::Socket::Client.new(socket, context, sync_close: true, hostname: tls_hostname)
    end

    @socket = socket
    @connection_id = @@next_connection_id.add(1)
  end

  def handshake(*, send_metadata = false, appname = nil, legacy = false, client_metadata : BSON? = nil, load_balanced : Bool = false)
    # First handshake uses legacy hello unless Server API or load-balanced is set.
    # Later heartbeats use hello when the server sent helloOk: true.
    use_legacy = legacy
    if send_metadata
      metadata = client_metadata
      if metadata.nil? && appname
        metadata = Handshake.client_document(appname)
      elsif metadata.nil?
        metadata = Handshake.client_document(nil)
      end
      body, _ = Commands::Hello.command(appname: appname, legacy: use_legacy, client: metadata, load_balanced: load_balanced)
    else
      cmd_name = use_legacy ? "isMaster" : "hello"
      body = BSON.build do |builder|
        builder[cmd_name] = 1
        builder["$db"] = "admin"
        builder["helloOk"] = true
        builder["backpressure"] = "2"
      end
    end

    add_sasl = @credentials.username && !@credentials.mechanism
    api = @options.server_api
    if add_sasl || api
      body.append do |builder|
        if add_sasl
          source = @credentials.source || ""
          source = "admin" if source.empty?
          builder["saslSupportedMechs"] = "#{source}.#{@credentials.username}"
        end
        if api
          builder["apiVersion"] = api.version
          builder["apiStrict"] = api.strict.as(Bool) unless api.strict.nil?
          builder["apiDeprecationErrors"] = api.deprecation_errors.as(Bool) unless api.deprecation_errors.nil?
        end
      end
    end

    request = Messages::OpMsg.new(body)

    response = uninitialized Mongo::Messages::OpMsg
    round_trip_time = Time.measure {
      send(request, Commands::Hello, log: false)
      response = receive(log: false)
    }

    if error = response.error?
      # Fallback to legacy isMaster if 'hello' command is not found (Mongo < 4.4)
      # The Versioned API spec mandates NOT using legacy commands if an API is requested.
      if !use_legacy && error.is_a?(Mongo::Error::Command) && error.code == 59 && @options.server_api.nil?
        return handshake(send_metadata: send_metadata, appname: appname, legacy: true, client_metadata: client_metadata, load_balanced: load_balanced)
      end
      raise error
    end

    result = Commands::Hello.result(response.body)

    if result.sasl_supported_mechs
      @sasl_supported_mechs = result.sasl_supported_mechs
    end

    @use_hello = !use_legacy || result.helloOk == true

    if load_balanced
      sid = result.serviceId
      unless sid
        raise Mongo::Error.new("Driver attempted to initialize in load balancing mode, but the server does not support this mode.")
      end
      @service_id = sid
    end

    {result, round_trip_time}
  end

  def apply_timeout(span : Time::Span?) : Nil
    socket = @socket
    if socket.responds_to?(:read_timeout=)
      socket.read_timeout = span
    end
    if socket.responds_to?(:write_timeout=)
      socket.write_timeout = span
    end
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
    return if server_description.type.rs_arbiter?
    return if @credentials.username.nil? && @credentials.password.nil? && @credentials.mechanism.nil?

    if mechanism = @credentials.mechanism
      mechanism = Auth::Mechanism.parse(mechanism.gsub('-', ""))
    elsif @sasl_supported_mechs
      mechanisms = @sasl_supported_mechs.try &.map { |mech|
        Auth::Mechanism.parse(mech.gsub('-', ""))
      }
      if mechanisms.try &.any? &.scram_sha256?
        mechanism = Auth::Mechanism::ScramSha256
      else
        mechanism = Auth::Mechanism::ScramSha1
      end
    else
      mechanism = Auth::Mechanism::ScramSha1
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

  def send(op_msg : Messages::OpMsg, command = nil, log = true, &block)
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

    message.to_io(socket)
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
        yield message
        return op_msg
      end
    end
  end

  def receive(log = false)
    receive(log: log) { }
  end

  def close
    @socket.close unless @socket.closed?
  end
end
