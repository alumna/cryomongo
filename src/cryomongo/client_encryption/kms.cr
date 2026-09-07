require "base64"

# Local KMS only, including named providers (`local:name2`). Cloud KMS stays out.
# :nodoc:
module Mongo::ClientEncryption::Kms
  extend self

  def local_provider?(name : String) : Bool
    name == "local" || name.starts_with?("local:")
  end

  # Validate local keys, then `mongocrypt_setopt_kms_providers`.
  # Official UTF stores the 96-byte master key as a base64 string.
  def apply(crypt : LibMongoCrypt::Crypt, kms_providers : BSON) : Nil
    count = 0
    kms_providers.each do |name, value, _code|
      unless local_provider?(name)
        raise Mongo::Error::Crypt.new("This version only supports local KMS (including named local:name). Got #{name}.")
      end
      unless value.is_a?(BSON)
        raise Mongo::Error::Crypt.new("kms_providers.#{name} must be a document with a 96-byte key.")
      end
      size = key_size(value)
      unless size
        raise Mongo::Error::Crypt.new("kms_providers.#{name}.key is required.")
      end
      unless size == Mongo::ClientEncryption::LOCAL_KEY_BYTES
        raise Mongo::Error::Crypt.new("Local master key must be #{Mongo::ClientEncryption::LOCAL_KEY_BYTES} bytes. Got #{size}.")
      end
      count += 1
    end
    if count == 0
      raise Mongo::Error::Crypt.new("kms_providers must include a local KMS provider.")
    end
    CBinary.with_bytes(kms_providers.data) do |bin|
      unless LibMongoCrypt.setopt_kms_providers(crypt, bin)
        CBinary.raise_crypt(crypt)
      end
    end
  end

  private def key_size(local : BSON) : Int32?
    local.each do |key, value, _code, _subtype|
      next unless key == "key"
      if value.is_a?(Bytes)
        return value.size
      elsif s = value.as?(String)
        return Base64.decode(s).size
      else
        raise Mongo::Error::Crypt.new("kms_providers local key must be binary or base64.")
      end
    end
    nil
  end
end
