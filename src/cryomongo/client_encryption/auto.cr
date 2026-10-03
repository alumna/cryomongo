# Auto-encryption engine. One mongocrypt_t per Client that opted in.
# FLE1 uses schemaMap. Queryable Encryption uses encryptedFieldsMap.
# Key-vault find and listCollections run with a per-fiber bypass on the parent
# client so they cannot re-enter encrypt and deadlock.
# :nodoc:
class Mongo::ClientEncryption::Auto < Mongo::AutoEncryption::Engine
  @crypt : LibMongoCrypt::Crypt
  @client : Mongo::Client
  @key_vault : Mongo::Collection
  @encrypted_fields_map : BSON?
  @lock = Sync::Mutex.new
  @closed = Atomic(Bool).new(false)
  @skip_encrypt : Bool
  @bypass_fiber : Fiber?

  def initialize(@client : Mongo::Client, opts : Mongo::AutoEncryption)
    @skip_encrypt = opts.bypass_auto_encryption
    @encrypted_fields_map = nil
    kv_client = opts.key_vault_client || @client
    db_name, coll_name = split_namespace(opts.key_vault_namespace)
    vault = kv_client[db_name][coll_name]
    vault.write_concern = Mongo::WriteConcern.new(w: "majority")
    vault.read_concern = Mongo::ReadConcern.new(level: "majority")
    @key_vault = vault

    crypt = LibMongoCrypt.crypt_new
    if crypt.null?
      raise Mongo::Error::Crypt.new("mongocrypt_new failed.")
    end

    begin
      CryptoHooks.install(crypt)
      Kms.apply(crypt, opts.kms_providers)
      if ms = opts.key_expiration_ms
        unless ms >= 0
          raise Mongo::Error::Crypt.new("key_expiration_ms must be >= 0.")
        end
        unless LibMongoCrypt.setopt_key_expiration(crypt, ms.to_u64)
          CBinary.raise_crypt(crypt)
        end
      end
      if schema = opts.schema_map
        CBinary.with_bytes(schema.data) do |bin|
          unless LibMongoCrypt.setopt_schema_map(crypt, bin)
            CBinary.raise_crypt(crypt)
          end
        end
      end
      if efc = opts.encrypted_fields_map
        owned = BSON.new(efc.data)
        @encrypted_fields_map = owned
        CBinary.with_bytes(owned.data) do |bin|
          unless LibMongoCrypt.setopt_encrypted_field_config_map(crypt, bin)
            CBinary.raise_crypt(crypt)
          end
        end
      end
      # Bypass query analysis: encrypt writes from the map / collinfo, no crypt_shared.
      if opts.bypass_query_analysis
        LibMongoCrypt.setopt_bypass_query_analysis(crypt)
      elsif !@skip_encrypt
        LibMongoCrypt.setopt_append_crypt_shared_lib_search_path(crypt, "$SYSTEM")
        if path = crypt_shared_path(opts.extra_options)
          LibMongoCrypt.setopt_set_crypt_shared_lib_path_override(crypt, path)
        end
      end
      # bulkWrite is sent to admin; collinfo must run on the op's database.
      LibMongoCrypt.setopt_use_need_mongo_collinfo_with_db_state(crypt)
      unless LibMongoCrypt.init(crypt)
        CBinary.raise_crypt(crypt)
      end
      unless @skip_encrypt || opts.bypass_query_analysis
        unless crypt_shared_loaded?(crypt)
          raise Mongo::Error::Crypt.new("crypt_shared was not loaded. Set extraOptions.cryptSharedLibPath or CRYPT_SHARED_LIB_PATH to mongo_crypt_v1.so (linux), .dylib (macos), or .dll (windows). mongocryptd is not implemented.")
        end
      end
    rescue ex
      LibMongoCrypt.crypt_destroy(crypt)
      raise ex
    end
    @crypt = crypt
  end

  def skip_encrypt? : Bool
    @skip_encrypt
  end

  # Clone the map entry so the caller can keep it after this method returns.
  def encrypted_fields_for(namespace : String) : BSON?
    map = @encrypted_fields_map
    return nil unless map
    map.each do |key, value, _code|
      next unless key == namespace
      return BSON.new(value.data) if value.is_a?(BSON)
      return nil
    end
    nil
  end

  # True only on the fiber that is fetching keys or collection info.
  def bypassing? : Bool
    fiber = @bypass_fiber
    !fiber.nil? && fiber == Fiber.current
  end

  def encrypt_command(body : BSON, sequences) : BSON
    @lock.synchronize do
      check_open
      db = command_db(body)
      merged = merge_sequences(body, sequences)
      @bypass_fiber = Fiber.current
      begin
        ctx = new_ctx
        begin
          CBinary.with_bytes(merged.data) do |bin|
            CBinary.raise_ctx(ctx) unless LibMongoCrypt.ctx_encrypt_init(ctx, db, -1, bin)
          end
          Context.run_auto(ctx, @key_vault, @client, db)
        ensure
          LibMongoCrypt.ctx_destroy(ctx)
        end
      ensure
        @bypass_fiber = nil
      end
    end
  end

  def decrypt_reply(reply : BSON) : BSON
    @lock.synchronize do
      check_open
      db = command_db?(reply) || ""
      @bypass_fiber = Fiber.current
      begin
        ctx = new_ctx
        begin
          CBinary.with_bytes(reply.data) do |bin|
            CBinary.raise_ctx(ctx) unless LibMongoCrypt.ctx_decrypt_init(ctx, bin)
          end
          Context.run_auto(ctx, @key_vault, @client, db)
        ensure
          LibMongoCrypt.ctx_destroy(ctx)
        end
      ensure
        @bypass_fiber = nil
      end
    end
  end

  def close : Nil
    @lock.synchronize do
      return unless @closed.compare_and_set(false, true)
      LibMongoCrypt.crypt_destroy(@crypt)
      @crypt = Pointer(Void).null.as(LibMongoCrypt::Crypt)
    end
  end

  private def check_open : Nil
    if @closed.get
      raise Mongo::Error::Crypt.new("Auto-encryption is closed.")
    end
  end

  private def new_ctx : LibMongoCrypt::Ctx
    ctx = LibMongoCrypt.ctx_new(@crypt)
    if ctx.null?
      raise Mongo::Error::Crypt.new("mongocrypt_ctx_new failed.")
    end
    ctx
  end

  private def command_db(body : BSON) : String
    db = command_db?(body)
    unless db
      raise Mongo::Error::Crypt.new("Auto-encryption command has no $db field.")
    end
    db
  end

  private def command_db?(body : BSON) : String?
    body.each do |key, value, _code|
      next unless key == "$db"
      return value.as?(String)
    end
    nil
  end

  # Auto-encryption encrypts one BSON document (OP_MSG payload type 0).
  private def merge_sequences(body : BSON, sequences) : BSON
    return body unless sequences
    BSON.build do |builder|
      body.each do |key, value, code|
        if value.is_a?(BSON) && code.array?
          builder.append_array(key, value)
        else
          builder[key] = value
        end
      end
      sequences.each do |key, documents|
        next unless documents
        builder.array(key.to_s) do
          index = 0
          documents.each do |doc|
            builder[index.to_s] = BSON.new(doc)
            index += 1
          end
        end
      end
    end
  end

  private def crypt_shared_path(extra : BSON?) : String?
    if extra
      extra.each do |key, value, _code|
        next unless key == "cryptSharedLibPath"
        if s = value.as?(String)
          return s unless s.empty?
        end
      end
    end
    Mongo::AutoEncryption.crypt_shared_lib_path
  end

  private def crypt_shared_loaded?(crypt : LibMongoCrypt::Crypt) : Bool
    ptr = LibMongoCrypt.crypt_shared_lib_version_string(crypt, Pointer(UInt32).null)
    return false if ptr.null?
    !String.new(ptr).empty?
  end

  private def split_namespace(ns : String) : {String, String}
    dot = ns.index('.')
    if dot.nil? || dot == 0 || dot == ns.bytesize - 1
      raise Mongo::Error::Crypt.new("key_vault_namespace must be database.collection. Got #{ns}.")
    end
    {ns[0, dot], ns[dot + 1..]}
  end
end

Mongo::AutoEncryption.engine_builder = ->(client : Mongo::Client, opts : Mongo::AutoEncryption) : Mongo::AutoEncryption::Engine {
  Mongo::ClientEncryption::Auto.new(client, opts)
}
