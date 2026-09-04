# Crystal FFI for libmongocrypt. Default link is the vendored 1.20.4 .so
# (scripts/vendor-libmongocrypt.sh). Do not use @[Link("mongocrypt")] on that
# path: Crystal pkg-config would pick Ubuntu apt 1.17 and miss newer symbols.
# Linux official tarballs are nocrypto (no libcrypto NEEDED); OpenSSL hooks
# live in crypto_hooks.cr. USE_SYSTEM_LIBMONGOCRYPT=true uses pkg-config.
# :nodoc:
{% begin %}
  {% use_system = env("USE_SYSTEM_LIBMONGOCRYPT") == "true" %}
  {% if use_system %}
    {% exists = `pkg-config --exists libmongocrypt 2>/dev/null && printf yes || printf no`.chomp == "yes" %}
    {% unless exists %}
      {% raise "USE_SYSTEM_LIBMONGOCRYPT=true needs pkg-config libmongocrypt (>= 1.20.0). Run scripts/vendor-libmongocrypt.sh and leave the env unset to use official 1.20.4. Skip CSFLE with -Dwithout_libmongocrypt." %}
    {% end %}
    {% puts "USE_SYSTEM_LIBMONGOCRYPT=true: linking pkg-config libmongocrypt #{`pkg-config --modversion libmongocrypt 2>/dev/null`.chomp} (need >= 1.20.0)" %}
    # Backticks: the linker shell expands pkg-config and splits -l / -L words.
    @[Link(ldflags: "`pkg-config --libs libmongocrypt`")]
  {% else %}
    {% libdir = `cd "#{__DIR__}/../../../vendor/libmongocrypt/lib" 2>/dev/null && pwd || true`.chomp %}
    {% if libdir.empty? %}
      {% raise "Vendored libmongocrypt 1.20.4 is missing. Run scripts/vendor-libmongocrypt.sh. Distro packages: USE_SYSTEM_LIBMONGOCRYPT=true (needs >= 1.20.0). Skip CSFLE: -Dwithout_libmongocrypt." %}
    {% end %}
    # One flag per annotation. A single ldflags string with spaces is passed
    # as one cc argument, so -lmongocrypt would never reach the linker.
    @[Link(ldflags: {{ "-L#{libdir}" }})]
    @[Link(ldflags: "-lmongocrypt")]
    {% unless flag?(:win32) %}
      {% unless flag?(:darwin) %}
        # DT_RPATH is searched before LD_LIBRARY_PATH, so apt libmongocrypt
        # cannot win at runtime.
        @[Link(ldflags: "-Wl,--disable-new-dtags")]
      {% end %}
      @[Link(ldflags: {{ "-Wl,-rpath,#{libdir}" }})]
    {% end %}
  {% end %}
{% end %}
lib LibMongoCrypt
  type Crypt = Void*
  type Ctx = Void*
  type Status = Void*
  type Binary = Void*

  alias CryptoFn = (Void*, Binary, Binary, Binary, Binary, UInt32*, Status) -> Bool
  alias HmacFn = (Void*, Binary, Binary, Binary, Status) -> Bool
  alias HashFn = (Void*, Binary, Binary, Status) -> Bool
  alias RandomFn = (Void*, Binary, UInt32, Status) -> Bool

  enum StatusType
    Ok               = 0
    ErrorClient      = 1
    ErrorKms         = 2
    ErrorCryptShared = 3
  end

  # Values match mongocrypt_ctx_state_t in mongocrypt.h.
  enum CtxState
    Error                   = 0
    NeedMongoCollinfo       = 1
    NeedMongoMarkings       = 2
    NeedMongoKeys           = 3
    NeedKms                 = 4
    Ready                   = 5
    Done                    = 6
    NeedKmsCredentials      = 7
    NeedMongoCollinfoWithDb = 8
  end

  fun version = mongocrypt_version(len : UInt32*) : LibC::Char*

  fun binary_new = mongocrypt_binary_new : Binary
  fun binary_new_from_data = mongocrypt_binary_new_from_data(data : UInt8*, len : UInt32) : Binary
  fun binary_data = mongocrypt_binary_data(binary : Binary) : UInt8*
  fun binary_len = mongocrypt_binary_len(binary : Binary) : UInt32
  fun binary_destroy = mongocrypt_binary_destroy(binary : Binary)

  fun status_new = mongocrypt_status_new : Status
  fun status_type = mongocrypt_status_type(status : Status) : StatusType
  fun status_code = mongocrypt_status_code(status : Status) : UInt32
  fun status_message = mongocrypt_status_message(status : Status, len : UInt32*) : LibC::Char*
  fun status_ok = mongocrypt_status_ok(status : Status) : Bool
  fun status_set = mongocrypt_status_set(status : Status, type : StatusType, code : UInt32, message : LibC::Char*, message_len : Int32)
  fun status_destroy = mongocrypt_status_destroy(status : Status)

  fun crypt_new = mongocrypt_new : Crypt
  fun setopt_kms_provider_local = mongocrypt_setopt_kms_provider_local(crypt : Crypt, key : Binary) : Bool
  # BSON map of provider name → credentials. Needed for named local (`local:name`).
  fun setopt_kms_providers = mongocrypt_setopt_kms_providers(crypt : Crypt, kms_providers : Binary) : Bool
  # Data-key cache TTL in milliseconds. Zero means the cache does not expire.
  fun setopt_key_expiration = mongocrypt_setopt_key_expiration(crypt : Crypt, cache_expiration_ms : UInt64) : Bool
  fun setopt_schema_map = mongocrypt_setopt_schema_map(crypt : Crypt, schema_map : Binary) : Bool
  fun setopt_encrypted_field_config_map = mongocrypt_setopt_encrypted_field_config_map(crypt : Crypt, efc_map : Binary) : Bool
  fun setopt_append_crypt_shared_lib_search_path = mongocrypt_setopt_append_crypt_shared_lib_search_path(crypt : Crypt, path : LibC::Char*)
  fun setopt_set_crypt_shared_lib_path_override = mongocrypt_setopt_set_crypt_shared_lib_path_override(crypt : Crypt, path : LibC::Char*)
  fun setopt_bypass_query_analysis = mongocrypt_setopt_bypass_query_analysis(crypt : Crypt)
  # Opt in so bulkWrite on admin can listCollections on the op namespace db.
  fun setopt_use_need_mongo_collinfo_with_db_state = mongocrypt_setopt_use_need_mongo_collinfo_with_db_state(crypt : Crypt)
  # Linux official 1.20.4 tarballs are nocrypto; the driver supplies OpenSSL.
  fun setopt_crypto_hooks = mongocrypt_setopt_crypto_hooks(crypt : Crypt, aes_256_cbc_encrypt : CryptoFn, aes_256_cbc_decrypt : CryptoFn, random : RandomFn, hmac_sha_512 : HmacFn, hmac_sha_256 : HmacFn, sha_256 : HashFn, ctx : Void*) : Bool
  fun setopt_aes_256_ctr = mongocrypt_setopt_aes_256_ctr(crypt : Crypt, aes_256_ctr_encrypt : CryptoFn, aes_256_ctr_decrypt : CryptoFn, ctx : Void*) : Bool
  fun init = mongocrypt_init(crypt : Crypt) : Bool
  fun status = mongocrypt_status(crypt : Crypt, status : Status) : Bool
  fun crypt_destroy = mongocrypt_destroy(crypt : Crypt)
  fun crypt_shared_lib_version_string = mongocrypt_crypt_shared_lib_version_string(crypt : Crypt, len : UInt32*) : LibC::Char*

  fun ctx_new = mongocrypt_ctx_new(crypt : Crypt) : Ctx
  fun ctx_status = mongocrypt_ctx_status(ctx : Ctx, status : Status) : Bool
  fun ctx_setopt_key_id = mongocrypt_ctx_setopt_key_id(ctx : Ctx, key_id : Binary) : Bool
  fun ctx_setopt_key_alt_name = mongocrypt_ctx_setopt_key_alt_name(ctx : Ctx, key_alt_name : Binary) : Bool
  fun ctx_setopt_algorithm = mongocrypt_ctx_setopt_algorithm(ctx : Ctx, algorithm : LibC::Char*, len : LibC::Int) : Bool
  fun ctx_setopt_masterkey_local = mongocrypt_ctx_setopt_masterkey_local(ctx : Ctx) : Bool
  fun ctx_setopt_key_encryption_key = mongocrypt_ctx_setopt_key_encryption_key(ctx : Ctx, bin : Binary) : Bool
  fun ctx_setopt_key_material = mongocrypt_ctx_setopt_key_material(ctx : Ctx, key_material : Binary) : Bool
  fun ctx_datakey_init = mongocrypt_ctx_datakey_init(ctx : Ctx) : Bool
  fun ctx_rewrap_many_datakey_init = mongocrypt_ctx_rewrap_many_datakey_init(ctx : Ctx, filter : Binary) : Bool
  fun ctx_encrypt_init = mongocrypt_ctx_encrypt_init(ctx : Ctx, db : LibC::Char*, db_len : Int32, cmd : Binary) : Bool
  fun ctx_explicit_encrypt_init = mongocrypt_ctx_explicit_encrypt_init(ctx : Ctx, msg : Binary) : Bool
  fun ctx_decrypt_init = mongocrypt_ctx_decrypt_init(ctx : Ctx, doc : Binary) : Bool
  fun ctx_explicit_decrypt_init = mongocrypt_ctx_explicit_decrypt_init(ctx : Ctx, msg : Binary) : Bool
  fun ctx_state = mongocrypt_ctx_state(ctx : Ctx) : CtxState
  fun ctx_mongo_op = mongocrypt_ctx_mongo_op(ctx : Ctx, op_bson : Binary) : Bool
  fun ctx_mongo_db = mongocrypt_ctx_mongo_db(ctx : Ctx) : LibC::Char*
  fun ctx_mongo_feed = mongocrypt_ctx_mongo_feed(ctx : Ctx, reply : Binary) : Bool
  fun ctx_mongo_done = mongocrypt_ctx_mongo_done(ctx : Ctx) : Bool
  fun ctx_finalize = mongocrypt_ctx_finalize(ctx : Ctx, out : Binary) : Bool
  fun ctx_destroy = mongocrypt_ctx_destroy(ctx : Ctx)
end
