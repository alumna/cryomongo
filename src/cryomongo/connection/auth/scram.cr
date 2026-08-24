require "openssl"
require "openssl/hmac"
require "base64"
require "digest/md5"
require "../../error"
require "../credentials"

class Mongo::Auth::Scram
  MIN_ITER_COUNT = 4096

  @server_nonce : String?
  @salt : Bytes?
  @iterations : Int32?
  @client_final : String?
  @client_key : Bytes?
  @server_key : Bytes?
  @client_signature : Bytes?
  @client_proof : String?
  @mongo_hashed_password : String?
  @id : Int32? = nil
  @server_first : String? = nil

  private def safe_salt : Bytes
    @salt || raise Mongo::Error.new("SCRAM salt is not initialized")
  end

  private def safe_iterations : Int32
    @iterations || raise Mongo::Error.new("SCRAM iterations are not initialized")
  end

  def initialize(mechanism : Mongo::Auth::Mechanism, @credentials : Credentials)
    if mechanism.scram_sha1?
      @mechanism_string = "SCRAM-SHA-1"
      @digest = OpenSSL::Digest.new("SHA1")
    elsif mechanism.scram_sha256?
      @mechanism_string = "SCRAM-SHA-256"
      @digest = OpenSSL::Digest.new("SHA256")
    else
      raise Mongo::Error.new "Invalid SCRAM mechanism: #{mechanism}"
    end
    @mechanism = mechanism
    @client_nonce = Random::Secure.base64
  end

  private def auth_source : String
    source = @credentials.source || ""
    source.empty? ? "admin" : source
  end

  # Nested hello document uses `db`, not `$db`. MongoDB 8.0 always accepts skipEmptyExchange.
  def start_document : BSON
    BSON.build do |builder|
      builder["saslStart"] = 1
      builder["mechanism"] = @mechanism_string
      builder["payload"] = client_first_payload.to_slice
      builder["db"] = auth_source
      builder["options"] = BSON.build do |opts|
        opts["skipEmptyExchange"] = true
      end
    end
  end

  def authenticate(connection : Mongo::Connection)
    source = auth_source
    request = Messages::OpMsg.new({
      saslStart: 1,
      mechanism: @mechanism_string,
      "$db":     source,
      options:   {skipEmptyExchange: true},
      payload:   client_first_payload.to_slice,
    })
    connection.send(request, "saslStart")
    response = connection.receive
    if error = response.error?
      raise error
    end
    process_server_first(response.body)
    send_client_final_and_finish(connection, source)
  end

  # Hello already ran saslStart as speculativeAuthenticate. Continue with saslContinue.
  def continue_from_hello(connection : Mongo::Connection, reply : BSON)
    process_server_first(reply)
    send_client_final_and_finish(connection, auth_source)
  end

  private def conversation_id(doc : BSON) : Int32
    value = doc["conversationId"]
    case value
    when Int32
      value
    when Int64
      value.to_i32
    else
      raise Mongo::Error.new("SCRAM conversationId is missing")
    end
  end

  private def process_server_first(reply_document : BSON)
    @id = conversation_id(reply_document)
    payload_data = String.new(reply_document["payload"].as(Bytes))
    @server_first = payload_data
    parsed_data = parse_payload(payload_data)
    @server_nonce = parsed_data["r"]
    @salt = Base64.decode(parsed_data["s"])
    @iterations = parsed_data["i"].to_i.tap do |i|
      if i < MIN_ITER_COUNT
        raise Mongo::Error.new "Insufficient iteration count: #{i}, min: #{MIN_ITER_COUNT}"
      end
    end
  end

  private def send_client_final_and_finish(connection : Mongo::Connection, source : String)
    server_first = @server_first || raise Mongo::Error.new("SCRAM server-first message is missing")
    id = @id || raise Mongo::Error.new("SCRAM conversationId is missing")
    # AuthMessage := client-first-message-bare + "," + server-first-message + "," +
    #                client-final-message-without-proof
    auth_message = "#{first_bare},#{server_first},#{without_proof}"

    validate_server_nonce!

    request = Messages::OpMsg.new({
      saslContinue:   1,
      conversationId: id,
      "$db":          source,
      payload:        client_final_message(auth_message).to_slice,
    })
    connection.send(request, "saslContinue")

    response = connection.receive
    if error = response.error?
      raise error
    end
    reply_document = response.body
    payload_data = String.new(reply_document["payload"].as(Bytes))
    parsed_data = parse_payload(payload_data)
    check_server_signature(server_key, auth_message, parsed_data)

    loop do
      break if reply_document["done"] == true

      request = Messages::OpMsg.new({
        saslContinue:   1,
        conversationId: id,
        "$db":          source,
        payload:        "".to_slice,
      })
      connection.send(request, "saslContinue")
      response = connection.receive
      if error = response.error?
        raise error
      end
      reply_document = response.body
    end
  end

  def first_bare
    raise Mongo::Error.new "Username is missing" unless username = @credentials.username
    encoded_name = username.gsub do |char|
      case char
      when '=' then "=3D"
      when ',' then "=2C"
      else          char
      end
    end
    @first_bare ||= "n=#{encoded_name},r=#{@client_nonce}"
  end

  def without_proof
    @without_proof ||= "c=biws,r=#{@server_nonce}"
  end

  def client_first_payload
    "n,,#{first_bare}"
  end

  def client_final_message(auth_message)
    "#{without_proof},p=#{client_final(auth_message)}"
  end

  def client_final(auth_message)
    @client_final ||= client_proof(client_key, client_signature(stored_key(client_key), auth_message))
  end

  # ClientProof := ClientKey XOR ClientSignature
  def client_proof(key, signature)
    @client_proof ||= Base64.strict_encode(xor(key, signature))
  end

  # ClientSignature := HMAC(StoredKey, AuthMessage)
  def client_signature(key, message)
    @client_signature ||= hmac(key, message)
  end

  # StoredKey := H(ClientKey)
  def stored_key(key)
    h(key)
  end

  def h(string)
    @digest.reset
    @digest.update(string)
    @digest.dup.final
  end

  # ClientKey := HMAC(SaltedPassword, "Client Key")
  def client_key
    @client_key ||= hmac(salted_password, "Client Key")
  end

  def server_key
    @server_key ||= hmac(salted_password, "Server Key")
  end

  def hmac(key : Bytes, data : String | Bytes)
    if @mechanism.scram_sha1?
      OpenSSL::HMAC.digest(:sha1, key, data)
    else
      OpenSSL::HMAC.digest(:sha256, key, data)
    end
  end

  def xor(first, second)
    byte_array = first.zip(second).map { |(a, b)| a ^ b }
    Slice.new(byte_array.size) { |i| byte_array[i] }
  end

  # SaltedPassword := Hi(Normalize(password), salt, i)
  def salted_password
    if @mechanism.scram_sha1?
      # See: https://github.com/mongodb/specifications/blob/master/source/auth/auth.rst#scram-sha-1
      hi(mongo_hashed_password, safe_salt, safe_iterations)
    else
      # SCRAM-SHA-256: SASLprep the password. Usernames are not prepared.
      hi(Mongo::Auth::Saslprep.prepare(@credentials.password || ""), safe_salt, safe_iterations)
    end
  end

  def mongo_hashed_password
    pwd = "#{@credentials.username}:mongo:#{@credentials.password}"
    @mongo_hashed_password ||= Digest::MD5.hexdigest(pwd)
  end

  def hi(data : String, salt : Bytes, iterations : Int32)
    OpenSSL::PKCS5.pbkdf2_hmac(
      data,
      salt,
      iterations: iterations,
      algorithm: @mechanism.scram_sha1? ? OpenSSL::Algorithm::SHA1 : OpenSSL::Algorithm::SHA256,
      key_size: @mechanism.scram_sha1? ? 20 : 32
    )
  end

  def server_signature(server_key, auth_message)
    @server_signature ||= Base64.strict_encode(hmac(server_key, auth_message))
  end

  def check_server_signature(server_key, auth_message, payload_data)
    if verifier = payload_data["v"]
      if compare_digest(verifier, server_signature(server_key, auth_message))
        @server_verified = true
      else
        raise Mongo::Error.new "Invalid server signature."
      end
    end
  end

  def compare_digest(a, b)
    check = a.bytesize ^ b.bytesize
    a.bytes.zip(b.bytes) { |x, y| check |= x ^ y.to_i }
    check == 0
  end

  def parse_payload(payload)
    hash = {} of String => String
    payload.split(',').reject(&.empty?).map do |pair|
      k, v = pair.split('=', 2)
      if k.empty?
        raise Mongo::Error.new "Payload malformed: missing key"
      end
      hash[k] = v
    end
    hash
  end

  def validate_server_nonce!
    if @client_nonce.nil? || @client_nonce.empty?
      raise Mongo::Error.new "Cannot validate server nonce when client nonce is nil or empty"
    end

    unless (nonce = @server_nonce) && nonce.starts_with?(@client_nonce)
      raise Mongo::Error.new "Invalid nonce"
    end
  end
end
