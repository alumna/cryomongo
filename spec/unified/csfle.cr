require "json"
require "semantic_version"

# UTF helpers for official CSFLE (local KMS, MongoDB 8.0).
# Cloud providers with `$$placeholder` are dropped. Real cloud credentials skip.
# Local `$$placeholder` keys use the official LOCAL_MASTERKEY.
module Mongo::Unified::Csfle
  extend self

  CLOUD_TYPES = {"aws", "azure", "gcp", "kmip"}

  def local_provider?(name : String) : Bool
    name == "local" || name.starts_with?("local:")
  end

  # Official prose LOCAL_MASTERKEY (96 bytes, base64).
  LOCAL_MASTERKEY = "Mng0NCt4ZHVUYUJCa1kxNkVyNUR1QURhZ2h2UzR2d2RrZzh0cFBwM3R6NmdWMDFBMUN3YkQ5aXRRMkhGRGdQV09wOGVNYUMxT2k3NjZKelhaQmRCZGJkTXVyZG9uSjFk"

  def placeholder?(value : JSON::Any) : Bool
    if h = value.as_h?
      return true if h.has_key?("$$placeholder")
      h.each_value { |v| return true if placeholder?(v) }
    elsif a = value.as_a?
      a.each { |v| return true if placeholder?(v) }
    end
    false
  end

  # Keep `local` and `local:name`. Drop unused cloud placeholders.
  def local_kms_providers(kms : JSON::Any) : JSON::Any
    h = kms.as_h?
    unless h
      raise Skip.new("kmsProviders must be a document")
    end
    kept = {} of String => JSON::Any
    h.each do |name, creds|
      type = name.split(':', 2)[0]
      if type == "local"
        kept[name] = fill_local_key(creds)
        next
      end
      unless CLOUD_TYPES.includes?(type)
        raise Skip.new("unknown KMS provider #{name}")
      end
      next if placeholder?(creds)
      raise Skip.new("cloud KMS #{name} is out of scope")
    end
    if kept.empty?
      raise Skip.new("no local KMS in kmsProviders")
    end
    JSON::Any.new(kept)
  end

  # UTF `local.key: { $$placeholder: 1 }` → official LOCAL_MASTERKEY.
  def fill_local_key(creds : JSON::Any) : JSON::Any
    h = creds.as_h?
    return creds unless h
    key = h["key"]?
    return creds unless key
    return creds unless placeholder?(key)
    JSON::Any.new({"key" => JSON::Any.new(LOCAL_MASTERKEY)})
  end

  def crypt_shared_path : String?
    if p = Mongo::AutoEncryption.crypt_shared_lib_path
      return p if File.file?(p)
    end
    {"tmp/mongo_crypt_v1.so", "/usr/local/lib/mongo_crypt_v1.so"}.each do |p|
      return File.expand_path(p) if File.file?(p)
    end
    nil
  end

  def supported? : Bool
    Mongo::ClientEncryption.lib_linked? && !crypt_shared_path.nil?
  end

  def libmongocrypt_at_least?(min : String) : Bool
    ver = Mongo::ClientEncryption.lib_version
    return false unless ver
    parse_semver(ver) >= parse_semver(min)
  end

  def parse_semver(value : String) : SemanticVersion
    parts = value.split(/[^0-9]+/).reject(&.empty?)
    while parts.size < 3
      parts << "0"
    end
    SemanticVersion.parse(parts[0..2].join("."))
  end

  def json_i64(value : JSON::Any?) : Int64?
    return nil unless value
    if i = value.as_i64?
      i
    elsif i = value.as_i?
      i.to_i64
    elsif h = value.as_h?
      if n = h["$numberLong"]? || h["$numberInt"]?
        n.as_s.to_i64
      end
    end
  end
end
