require "./error"

# So this file can load before the rest of `Client`.
class Mongo::Client
end

# Public auto-encryption options. This type has no libmongocrypt C handles (D36).
#
# Automatic encryption needs MongoDB Enterprise **crypt_shared** (`mongo_crypt_v1.so`)
# or, in other drivers, mongocryptd. This driver uses crypt_shared only.
# Set `extra_options["cryptSharedLibPath"]` or `CRYPT_SHARED_LIB_PATH`.
#
# A local `schema_map` is safer than a schema from the server. It only configures
# automatic encryption; other JSON Schema rules are not enforced and error.
# Local KMS includes named providers (`local:name`). Cloud KMS stays out.
# A local `encrypted_fields_map` is safer than `encryptedFields` from the server
# (Queryable Encryption). Do not put the same collection in both maps.
#
# Automatic encryption is an Enterprise feature and applies to collection commands.
# `bypass_auto_encryption: true` skips encrypt and still decrypts. Key-vault
# find/insert on this client bypass auto-encryption so they cannot deadlock.
# `bypass_query_analysis: true` still encrypts writes from the local map / server
# encryptedFields, and does not load crypt_shared.
#
# All `Mongo::Client` objects in one process should use the same crypt_shared path.
class Mongo::AutoEncryption
  getter key_vault_namespace : String
  getter kms_providers : BSON
  getter schema_map : BSON?
  getter encrypted_fields_map : BSON?
  getter extra_options : BSON?
  getter key_vault_client : Mongo::Client?
  getter bypass_auto_encryption : Bool
  getter bypass_query_analysis : Bool
  getter key_expiration_ms : Int64?

  def initialize(
    *,
    key_vault_namespace : String,
    kms_providers : BSON,
    schema_map : BSON? = nil,
    encrypted_fields_map : BSON? = nil,
    extra_options : BSON? = nil,
    key_vault_client : Mongo::Client? = nil,
    bypass_auto_encryption : Bool = false,
    bypass_query_analysis : Bool = false,
    key_expiration_ms : Int64? = nil,
  )
    @key_vault_namespace = key_vault_namespace
    @kms_providers = kms_providers
    @schema_map = schema_map
    @encrypted_fields_map = encrypted_fields_map
    @extra_options = extra_options
    @key_vault_client = key_vault_client
    @bypass_auto_encryption = bypass_auto_encryption
    @bypass_query_analysis = bypass_query_analysis
    @key_expiration_ms = key_expiration_ms
  end

  # Absolute path to `mongo_crypt_v1.so` from the environment, if set.
  def self.crypt_shared_lib_path : String?
    if p = ENV["CRYPT_SHARED_LIB_PATH"]?
      return p unless p.empty?
    end
    nil
  end

  # :nodoc:
  abstract class Engine
    abstract def encrypt_command(body : BSON, sequences) : BSON
    abstract def decrypt_reply(reply : BSON) : BSON
    abstract def bypassing? : Bool
    abstract def skip_encrypt? : Bool
    abstract def close : Nil

    # Queryable Encryption local map for one namespace, or nil.
    def encrypted_fields_for(_namespace : String) : BSON?
      nil
    end
  end

  @@engine_builder : (Mongo::Client, Mongo::AutoEncryption -> Engine)?

  # :nodoc:
  def self.engine_builder=(builder : Mongo::Client, Mongo::AutoEncryption -> Engine) : Nil
    @@engine_builder = builder
  end

  # :nodoc:
  def self.open_engine(client : Mongo::Client, opts : Mongo::AutoEncryption) : Engine
    builder = @@engine_builder
    unless builder
      raise Mongo::Error::Crypt.new("Auto-encryption needs libmongocrypt. Install libmongocrypt-dev, then rebuild without -Dwithout_libmongocrypt.")
    end
    builder.call(client, opts)
  end
end
