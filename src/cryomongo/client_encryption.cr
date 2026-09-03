require "sync"

{% begin %}
  {% linked = false %}
  {% unless flag?(:without_libmongocrypt) %}
    {% if flag?(:libmongocrypt) %}
      {% linked = true %}
    {% else %}
      {% linked = `pkg-config --exists libmongocrypt 2>/dev/null && printf yes || printf no`.stringify.includes?("yes") %}
    {% end %}
  {% end %}

  {% if linked %}
    require "./client_encryption/lib"
  {% end %}

  # Explicit client-side field level encryption (CSFLE).
  #
  # Needs system **libmongocrypt**. When that library is missing, the rest of the
  # driver still compiles. Creating a `ClientEncryption` then raises
  # `Mongo::Error::Crypt`. Compile with `-Dwithout_libmongocrypt` to skip the
  # link. Compile with `-Dlibmongocrypt` to require the link.
  #
  # This slice is local KMS only: `create_data_key`, `encrypt`, and `decrypt`.
  # Encrypted values are BSON binary subtype `0x06`.
  class Mongo::ClientEncryption
    LIB_LINKED = {{ linked }}
  end

  {% if linked %}
    require "./client_encryption/c_binary"
    require "./client_encryption/context"
  {% end %}

  class Mongo::ClientEncryption
    # FLE1 deterministic algorithm (same plaintext → same ciphertext).
    ALGORITHM_DETERMINISTIC = "AEAD_AES_256_CBC_HMAC_SHA_512-Deterministic"
    # FLE1 random algorithm (same plaintext → different ciphertext).
    ALGORITHM_RANDOM = "AEAD_AES_256_CBC_HMAC_SHA_512-Random"

    LOCAL_KEY_BYTES = 96

    MISSING_LIB = "ClientEncryption needs libmongocrypt. Install libmongocrypt-dev, then rebuild without -Dwithout_libmongocrypt. Specs skip when the library is missing."

    def self.lib_linked? : Bool
      LIB_LINKED
    end

    {% if linked %}
      @crypt : LibMongoCrypt::Crypt
      @key_vault : Mongo::Collection
      @lock = Sync::Mutex.new
      @closed = Atomic(Bool).new(false)
    {% end %}

    # *key_vault_namespace* is `"database.collection"`. *kms_providers* must be
    # BSON `{ "local" => { "key" => <96-byte binary> } }`.
    def initialize(
      key_vault_client : Mongo::Client,
      *,
      key_vault_namespace : String,
      kms_providers : BSON,
    )
      {% unless linked %}
        raise Mongo::Error::Crypt.new(MISSING_LIB)
      {% else %}
        master_key = local_master_key(kms_providers)
        db_name, coll_name = split_namespace(key_vault_namespace)
        vault = key_vault_client[db_name][coll_name]
        vault.write_concern = Mongo::WriteConcern.new(w: "majority")
        vault.read_concern = Mongo::ReadConcern.new(level: "majority")
        @key_vault = vault

        crypt = LibMongoCrypt.crypt_new
        if crypt.null?
          raise Mongo::Error::Crypt.new("mongocrypt_new failed.")
        end
        CBinary.with_bytes(master_key) do |bin|
          unless LibMongoCrypt.setopt_kms_provider_local(crypt, bin)
            message, code = CBinary.crypt_message(crypt)
            LibMongoCrypt.crypt_destroy(crypt)
            raise Mongo::Error::Crypt.new(message, code: code)
          end
        end
        unless LibMongoCrypt.init(crypt)
          message, code = CBinary.crypt_message(crypt)
          LibMongoCrypt.crypt_destroy(crypt)
          raise Mongo::Error::Crypt.new(message, code: code)
        end
        @crypt = crypt
      {% end %}
    end

    # Create a data key in the key vault. Returns the `_id` UUID (subtype 0x04).
    def create_data_key(kms_provider : String, *, key_alt_names : Array(String)? = nil) : BSON::Binary
      {% unless linked %}
        raise Mongo::Error::Crypt.new(MISSING_LIB)
      {% else %}
        unless kms_provider == "local"
          raise Mongo::Error::Crypt.new("create_data_key only supports local KMS in this version. Got #{kms_provider}.")
        end
        @lock.synchronize do
          check_open
          ctx = new_ctx
          begin
            CBinary.raise_ctx(ctx) unless LibMongoCrypt.ctx_setopt_masterkey_local(ctx)
            set_key_alt_names(ctx, key_alt_names)
            CBinary.raise_ctx(ctx) unless LibMongoCrypt.ctx_datakey_init(ctx)
            key_doc = Context.run(ctx, @key_vault)
            @key_vault.insert_one(key_doc)
            uuid_binary(key_doc, "_id")
          ensure
            LibMongoCrypt.ctx_destroy(ctx)
          end
        end
      {% end %}
    end

    # Encrypt *value*. Pass either *key_id* (UUID binary) or *key_alt_name*.
    # Returns BSON binary subtype `0x06`.
    def encrypt(value, *, algorithm : String, key_id : BSON::Binary? = nil, key_alt_name : String? = nil) : BSON::Binary
      {% unless linked %}
        raise Mongo::Error::Crypt.new(MISSING_LIB)
      {% else %}
        if key_id && key_alt_name
          raise Mongo::Error::Crypt.new("encrypt accepts either key_id or key_alt_name, not both.")
        end
        unless key_id || key_alt_name
          raise Mongo::Error::Crypt.new("encrypt needs key_id or key_alt_name.")
        end
        @lock.synchronize do
          check_open
          ctx = new_ctx
          begin
            if id = key_id
              set_key_id(ctx, id)
            end
            if name = key_alt_name
              set_key_alt_names(ctx, [name])
            end
            CBinary.raise_ctx(ctx) unless LibMongoCrypt.ctx_setopt_algorithm(ctx, algorithm, -1)
            msg = wrap_v(value)
            CBinary.with_bytes(msg.data) do |bin|
              CBinary.raise_ctx(ctx) unless LibMongoCrypt.ctx_explicit_encrypt_init(ctx, bin)
            end
            encrypted_binary(Context.run(ctx, @key_vault))
          ensure
            LibMongoCrypt.ctx_destroy(ctx)
          end
        end
      {% end %}
    end

    # Decrypt a BSON binary subtype `0x06` value. Nested BSON / Bytes are copied.
    def decrypt(value : BSON::Binary) : BSON::Value
      {% unless linked %}
        raise Mongo::Error::Crypt.new(MISSING_LIB)
      {% else %}
        @lock.synchronize do
          check_open
          ctx = new_ctx
          begin
            msg = wrap_v(value)
            CBinary.with_bytes(msg.data) do |bin|
              CBinary.raise_ctx(ctx) unless LibMongoCrypt.ctx_explicit_decrypt_init(ctx, bin)
            end
            decrypted_value(Context.run(ctx, @key_vault))
          ensure
            LibMongoCrypt.ctx_destroy(ctx)
          end
        end
      {% end %}
    end

    # Free the libmongocrypt handle. Does not close the key-vault client.
    def close : Nil
      {% if linked %}
        @lock.synchronize do
          return unless @closed.compare_and_set(false, true)
          LibMongoCrypt.crypt_destroy(@crypt)
        end
      {% end %}
    end

    # Last resort if the caller skips `#close`. Do not take work from this path.
    def finalize
      {% if linked %}
        return unless @closed.compare_and_set(false, true)
        LibMongoCrypt.crypt_destroy(@crypt)
      {% end %}
    end

    {% if linked %}
      private def check_open : Nil
        if @closed.get
          raise Mongo::Error::Crypt.new("ClientEncryption is closed.")
        end
      end

      private def new_ctx : LibMongoCrypt::Ctx
        ctx = LibMongoCrypt.ctx_new(@crypt)
        if ctx.null?
          raise Mongo::Error::Crypt.new("mongocrypt_ctx_new failed.")
        end
        ctx
      end

      private def set_key_id(ctx : LibMongoCrypt::Ctx, key_id : BSON::Binary) : Nil
        unless key_id.subtype.uuid? && key_id.data.size == 16
          raise Mongo::Error::Crypt.new("encrypt key_id must be a UUID (BSON binary subtype 0x04).")
        end
        CBinary.with_bytes(key_id.data) do |bin|
          CBinary.raise_ctx(ctx) unless LibMongoCrypt.ctx_setopt_key_id(ctx, bin)
        end
      end

      private def set_key_alt_names(ctx : LibMongoCrypt::Ctx, names : Array(String)?) : Nil
        return unless names
        names.each do |name|
          alt = BSON.build { |bson| bson["keyAltName"] = name }
          CBinary.with_bytes(alt.data) do |bin|
            CBinary.raise_ctx(ctx) unless LibMongoCrypt.ctx_setopt_key_alt_name(ctx, bin)
          end
        end
      end

      private def wrap_v(value) : BSON
        BSON.build { |bson| bson["v"] = value }
      end

      private def uuid_binary(doc : BSON, name : String) : BSON::Binary
        doc.each do |key, value, _code, subtype|
          next unless key == name
          case value
          when UUID
            return BSON::Binary.new(value)
          when Bytes
            st = subtype || BSON::Binary::SubType::UUID
            return BSON::Binary.new(st, value.clone)
          end
          raise Mongo::Error::Crypt.new("Data key #{name} is not a UUID binary.")
        end
        raise Mongo::Error::Crypt.new("Data key document has no #{name}.")
      end

      private def encrypted_binary(doc : BSON) : BSON::Binary
        doc.each do |key, value, code, subtype|
          next unless key == "v"
          unless code.binary? && value.is_a?(Bytes)
            raise Mongo::Error::Crypt.new("encrypt result is not BSON binary.")
          end
          st = subtype || BSON::Binary::SubType::EncryptedBSON
          unless st.encrypted_bson?
            raise Mongo::Error::Crypt.new("encrypt result must be BSON binary subtype 0x06. Got #{st}.")
          end
          return BSON::Binary.new(BSON::Binary::SubType::EncryptedBSON, value.clone)
        end
        raise Mongo::Error::Crypt.new("encrypt result has no v field.")
      end

      private def decrypted_value(doc : BSON) : BSON::Value
        doc.each do |key, value, _code, _subtype|
          next unless key == "v"
          case value
          when BSON
            return BSON.new(value.data)
          when Bytes
            return value.clone
          else
            return value
          end
        end
        raise Mongo::Error::Crypt.new("decrypt result has no v field.")
      end

      private def local_master_key(kms_providers : BSON) : Bytes
        kms_providers.each do |name, _value, _code|
          unless name == "local"
            raise Mongo::Error::Crypt.new("ClientEncryption only supports local KMS in this version. Got #{name}.")
          end
        end
        local = kms_providers["local"]?
        unless local.is_a?(BSON)
          raise Mongo::Error::Crypt.new("kms_providers.local must be a document with a 96-byte key.")
        end
        key_bytes : Bytes? = nil
        local.each do |key, value, _code, _subtype|
          next unless key == "key"
          if value.is_a?(Bytes)
            key_bytes = value.clone
          else
            raise Mongo::Error::Crypt.new("kms_providers.local.key must be binary.")
          end
        end
        bytes = key_bytes
        unless bytes
          raise Mongo::Error::Crypt.new("kms_providers.local.key is required.")
        end
        unless bytes.size == LOCAL_KEY_BYTES
          raise Mongo::Error::Crypt.new("Local master key must be #{LOCAL_KEY_BYTES} bytes. Got #{bytes.size}.")
        end
        bytes
      end

      private def split_namespace(ns : String) : {String, String}
        dot = ns.index('.')
        if dot.nil? || dot == 0 || dot == ns.bytesize - 1
          raise Mongo::Error::Crypt.new("key_vault_namespace must be database.collection. Got #{ns}.")
        end
        {ns[0, dot], ns[dot + 1..]}
      end
    {% end %}
  end
{% end %}
