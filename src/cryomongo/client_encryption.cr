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
  # This slice is local KMS only: `create_data_key`, `encrypt`, `decrypt`,
  # key-vault helpers, `rewrap_many_data_key`, and `create_encrypted_collection`.
  # Named local (`local:name`) is included. Auto-encryption (`Mongo::AutoEncryption`
  # on `Mongo::Client`) uses the same bindings, including Queryable Encryption
  # `encryptedFieldsMap`. Encrypted values are BSON binary subtype `0x06`.
  # Always call `#close`. There is no GC `finalize` that frees libmongocrypt
  # (see `#close`).
  class Mongo::ClientEncryption
    LIB_LINKED = {{ linked }}
    MISSING_LIB = "ClientEncryption needs libmongocrypt. Install libmongocrypt-dev, then rebuild without -Dwithout_libmongocrypt. Specs skip when the library is missing."
  end

  {% if linked %}
    require "./client_encryption/c_binary"
    require "./client_encryption/kms"
    require "./client_encryption/context"
    require "./client_encryption/auto"
    require "./client_encryption/encrypted_collection"
    require "./client_encryption/key_management"
  {% else %}
    Mongo::AutoEncryption.engine_builder = ->(client : Mongo::Client, opts : Mongo::AutoEncryption) : Mongo::AutoEncryption::Engine {
      raise Mongo::Error::Crypt.new(Mongo::ClientEncryption::MISSING_LIB)
    }
  {% end %}

  class Mongo::ClientEncryption
    # FLE1 deterministic algorithm (same plaintext → same ciphertext).
    ALGORITHM_DETERMINISTIC = "AEAD_AES_256_CBC_HMAC_SHA_512-Deterministic"
    # FLE1 random algorithm (same plaintext → different ciphertext).
    ALGORITHM_RANDOM = "AEAD_AES_256_CBC_HMAC_SHA_512-Random"

    LOCAL_KEY_BYTES = 96

    # Result of `#rewrap_many_data_key`. Nil bulk_write_result means no key matched.
    class RewrapManyDataKeyResult
      getter bulk_write_result : Mongo::Bulk::WriteResult?

      def initialize(@bulk_write_result : Mongo::Bulk::WriteResult? = nil)
      end
    end

    def self.lib_linked? : Bool
      LIB_LINKED
    end

    # libmongocrypt version string, or nil when the library is not linked.
    def self.lib_version : String?
      {% if linked %}
        ptr = LibMongoCrypt.version(Pointer(UInt32).null)
        return nil if ptr.null?
        String.new(ptr)
      {% else %}
        nil
      {% end %}
    end

    {% if linked %}
      @crypt : LibMongoCrypt::Crypt
      @key_vault : Mongo::Collection
      @lock = Sync::Mutex.new
      @closed = Atomic(Bool).new(false)
    {% end %}

    # *key_vault_namespace* is `"database.collection"`. *kms_providers* is local
    # KMS only: `{ "local" => { "key" => <96-byte binary or base64> } }` or a
    # named provider `{ "local:name" => { "key" => ... } }`.
    # *key_expiration_ms* is the data-key cache TTL. Nil keeps the lib default.
    def initialize(
      key_vault_client : Mongo::Client,
      *,
      key_vault_namespace : String,
      kms_providers : BSON,
      key_expiration_ms : Int64? = nil,
    )
      {% unless linked %}
        raise Mongo::Error::Crypt.new(MISSING_LIB)
      {% else %}
        db_name, coll_name = split_namespace(key_vault_namespace)
        vault = key_vault_client[db_name][coll_name]
        vault.write_concern = Mongo::WriteConcern.new(w: "majority")
        vault.read_concern = Mongo::ReadConcern.new(level: "majority")
        @key_vault = vault

        crypt = LibMongoCrypt.crypt_new
        if crypt.null?
          raise Mongo::Error::Crypt.new("mongocrypt_new failed.")
        end
        begin
          Kms.apply(crypt, kms_providers)
          if ms = key_expiration_ms
            unless ms >= 0
              raise Mongo::Error::Crypt.new("key_expiration_ms must be >= 0.")
            end
            unless LibMongoCrypt.setopt_key_expiration(crypt, ms.to_u64)
              CBinary.raise_crypt(crypt)
            end
          end
          unless LibMongoCrypt.init(crypt)
            CBinary.raise_crypt(crypt)
          end
        rescue ex
          LibMongoCrypt.crypt_destroy(crypt)
          raise ex
        end
        @crypt = crypt
      {% end %}
    end

    # Create a data key in the key vault. Returns the `_id` UUID (subtype 0x04).
    # *kms_provider* is `local` or `local:name`. *key_material* is 96 bytes when set.
    def create_data_key(
      kms_provider : String,
      *,
      key_alt_names : Array(String)? = nil,
      key_material : BSON::Binary | Bytes | Nil = nil,
      master_key : BSON? = nil,
    ) : BSON::Binary
      {% unless linked %}
        raise Mongo::Error::Crypt.new(MISSING_LIB)
      {% else %}
        unless Kms.local_provider?(kms_provider)
          raise Mongo::Error::Crypt.new("create_data_key only supports local KMS (including named local:name). Got #{kms_provider}.")
        end
        @lock.synchronize do
          check_open
          ctx = new_ctx
          begin
            set_master_key(ctx, kms_provider, master_key)
            set_key_alt_names(ctx, key_alt_names)
            set_key_material(ctx, key_material)
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

    {% unless linked %}
      # Create a Queryable Encryption collection. Generates data keys for null keyId.
      def create_encrypted_collection(
        database : Mongo::Database,
        name : String,
        *,
        encrypted_fields : BSON,
        kms_provider : String,
      ) : {Mongo::Collection, BSON}
        raise Mongo::Error::Crypt.new(MISSING_LIB)
      end

      def get_key(_id : BSON::Binary) : BSON?
        raise Mongo::Error::Crypt.new(MISSING_LIB)
      end

      def get_keys : Array(BSON)
        raise Mongo::Error::Crypt.new(MISSING_LIB)
      end

      def delete_key(_id : BSON::Binary) : Commands::Common::DeleteResult?
        raise Mongo::Error::Crypt.new(MISSING_LIB)
      end

      def add_key_alt_name(_id : BSON::Binary, _key_alt_name : String) : BSON?
        raise Mongo::Error::Crypt.new(MISSING_LIB)
      end

      def remove_key_alt_name(_id : BSON::Binary, _key_alt_name : String) : BSON?
        raise Mongo::Error::Crypt.new(MISSING_LIB)
      end

      def get_key_by_alt_name(_key_alt_name : String) : BSON?
        raise Mongo::Error::Crypt.new(MISSING_LIB)
      end

      def rewrap_many_data_key(_filter : BSON, *, provider : String? = nil, master_key : BSON? = nil) : RewrapManyDataKeyResult
        raise Mongo::Error::Crypt.new(MISSING_LIB)
      end
    {% end %}

    # Free the libmongocrypt handle. Does not close the key-vault client.
    #
    # Call this from the owning fiber. Do not add a GC `finalize` that calls
    # `mongocrypt_destroy`: finalize runs on a GC thread during `GC_malloc`
    # (same rule as `Cursor#finalize`). libmongocrypt uses libc malloc/free, so
    # destroy-from-GC double-frees or SIGSEGV (`_mongocrypt_buffer_cleanup`).
    def close : Nil
      {% if linked %}
        @lock.synchronize do
          return unless @closed.compare_and_set(false, true)
          LibMongoCrypt.crypt_destroy(@crypt)
          @crypt = Pointer(Void).null.as(LibMongoCrypt::Crypt)
        end
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

      private       def set_key_alt_names(ctx : LibMongoCrypt::Ctx, names : Array(String)?) : Nil
        return unless names
        names.each do |name|
          alt = BSON.build { |bson| bson["keyAltName"] = name }
          CBinary.with_bytes(alt.data) do |bin|
            CBinary.raise_ctx(ctx) unless LibMongoCrypt.ctx_setopt_key_alt_name(ctx, bin)
          end
        end
      end

      # `{ provider: "local" }` or `{ provider: "local:name" }`. Extra masterKey
      # fields are copied when present (unused for local).
      def set_master_key(ctx : LibMongoCrypt::Ctx, kms_provider : String, master_key : BSON?) : Nil
        kek = BSON.build do |bson|
          bson["provider"] = kms_provider
          if mk = master_key
            mk.each do |key, value, code, subtype|
              next if key == "provider"
              append_cloned(bson, key, value, code, subtype)
            end
          end
        end
        CBinary.with_bytes(kek.data) do |bin|
          CBinary.raise_ctx(ctx) unless LibMongoCrypt.ctx_setopt_key_encryption_key(ctx, bin)
        end
      end

      def set_key_material(ctx : LibMongoCrypt::Ctx, key_material : BSON::Binary | Bytes | Nil) : Nil
        return unless key_material
        bytes = case key_material
                when BSON::Binary
                  key_material.data
                else
                  key_material
                end
        doc = BSON.build do |bson|
          bson["keyMaterial"] = BSON::Binary.new(BSON::Binary::SubType::Generic, bytes)
        end
        CBinary.with_bytes(doc.data) do |bin|
          CBinary.raise_ctx(ctx) unless LibMongoCrypt.ctx_setopt_key_material(ctx, bin)
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
