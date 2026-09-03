# Crystal FFI for system libmongocrypt. Link only libmongocrypt; the shared
# object already loads libcrypto and libbson2.
# :nodoc:
@[Link("mongocrypt")]
lib LibMongoCrypt
  type Crypt = Void*
  type Ctx = Void*
  type Status = Void*
  type Binary = Void*

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
  fun status_destroy = mongocrypt_status_destroy(status : Status)

  fun crypt_new = mongocrypt_new : Crypt
  fun setopt_kms_provider_local = mongocrypt_setopt_kms_provider_local(crypt : Crypt, key : Binary) : Bool
  fun init = mongocrypt_init(crypt : Crypt) : Bool
  fun status = mongocrypt_status(crypt : Crypt, status : Status) : Bool
  fun crypt_destroy = mongocrypt_destroy(crypt : Crypt)

  fun ctx_new = mongocrypt_ctx_new(crypt : Crypt) : Ctx
  fun ctx_status = mongocrypt_ctx_status(ctx : Ctx, status : Status) : Bool
  fun ctx_setopt_key_id = mongocrypt_ctx_setopt_key_id(ctx : Ctx, key_id : Binary) : Bool
  fun ctx_setopt_key_alt_name = mongocrypt_ctx_setopt_key_alt_name(ctx : Ctx, key_alt_name : Binary) : Bool
  fun ctx_setopt_algorithm = mongocrypt_ctx_setopt_algorithm(ctx : Ctx, algorithm : LibC::Char*, len : LibC::Int) : Bool
  fun ctx_setopt_masterkey_local = mongocrypt_ctx_setopt_masterkey_local(ctx : Ctx) : Bool
  fun ctx_datakey_init = mongocrypt_ctx_datakey_init(ctx : Ctx) : Bool
  fun ctx_explicit_encrypt_init = mongocrypt_ctx_explicit_encrypt_init(ctx : Ctx, msg : Binary) : Bool
  fun ctx_explicit_decrypt_init = mongocrypt_ctx_explicit_decrypt_init(ctx : Ctx, msg : Binary) : Bool
  fun ctx_state = mongocrypt_ctx_state(ctx : Ctx) : CtxState
  fun ctx_mongo_op = mongocrypt_ctx_mongo_op(ctx : Ctx, op_bson : Binary) : Bool
  fun ctx_mongo_feed = mongocrypt_ctx_mongo_feed(ctx : Ctx, reply : Binary) : Bool
  fun ctx_mongo_done = mongocrypt_ctx_mongo_done(ctx : Ctx) : Bool
  fun ctx_finalize = mongocrypt_ctx_finalize(ctx : Ctx, out : Binary) : Bool
  fun ctx_destroy = mongocrypt_ctx_destroy(ctx : Ctx)
end
