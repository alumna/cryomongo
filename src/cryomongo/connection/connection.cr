require "openssl"
require "./credentials"
require "./auth"

# :nodoc:
struct Mongo::Connection
  getter server_description : SDAM::ServerDescription
  getter credentials : Mongo::Credentials
  getter socket : IO
  @sasl_supported_mechs : Array(String)? = nil

  def initialize(@server_description : SDAM::ServerDescription, @credentials : Mongo::Credentials, @options : Mongo::Options, is_monitor : Bool = false)
    if @server_description.address.ends_with? ".sock"
      socket = UNIXSocket.new(@server_description.address)
    else
      split = @server_description.address.split(':')
      host = split[0]
      socket = TCPSocket.new(split[0], split[1]? || 27017, dns_timeout: @options.connect_timeout, connect_timeout: @options.connect_timeout)
      socket.tcp_nodelay = true
    end

    timeout = is_monitor ? @options.connect_timeout : @options.socket_timeout
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
      socket = OpenSSL::SSL::Socket::Client.new(socket, context, sync_close: true, hostname: host)
    end

    @socket = socket
  end

  def handshake(*, send_metadata = false, appname = nil, legacy = false)
    if send_metadata
      body, _ = Commands::Hello.command(appname: appname, legacy: legacy)
    else
      cmd_name = legacy ? "isMaster" : "hello"
      body = BSON.new({cmd_name => 1, "$db" => "admin", "helloOk" => true})
    end

    if @credentials.username && !@credentials.mechanism
      source = @credentials.source || ""
      source = "admin" if source.empty?
      body["saslSupportedMechs"] = "#{source}.#{@credentials.username}"
    end

    request = Messages::OpMsg.new(body)

    response = uninitialized Mongo::Messages::OpMsg
    round_trip_time = Time.measure {
      send(request, Commands::Hello, log: false)
      response = receive(log: false)
    }

    if error = response.error?
      # Fallback to legacy isMaster if 'hello' command is not found (Mongo < 4.4)
      if !legacy && error.is_a?(Mongo::Error::Command) && error.code == 59
        return handshake(send_metadata: send_metadata, appname: appname, legacy: true)
      end
      raise error
    end

    result = Commands::Hello.result(response.body)

    if result.sasl_supported_mechs
      @sasl_supported_mechs = result.sasl_supported_mechs
    end

    {result, round_trip_time}
  end

  def self.average_round_trip_time(round_trip_time : Time::Span, old_rtt : Time::Span?)
    # see: https://github.com/mongodb/specifications/blob/master/source/server-selection/server-selection.rst#calculation-of-average-round-trip-times
    if old_rtt
      alpha = 0.2
      (0.2 * round_trip_time.milliseconds + (1 - alpha) * old_rtt.milliseconds).milliseconds
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
      "(#{server_description.address}) >> #{"[#{message.header.request_id}]".ljust(8)} Body: #{op_msg.body.to_json}"
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
