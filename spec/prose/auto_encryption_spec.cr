require "../spec_helper"
require "random/secure"

private def local_kms_providers(master_key : Bytes) : BSON
  BSON.build do |bson|
    bson.document("local") do
      bson["key"] = BSON::Binary.new(:generic, master_key)
    end
  end
end

private def crypt_shared_lib_path : String?
  spec_crypt_shared_path
end

private def fle1_schema_map(namespace : String, key_id : BSON::Binary) : BSON
  BSON.build do |bson|
    bson.document(namespace) do
      bson["bsonType"] = "object"
      bson.document("properties") do
        bson.document("ssn") do
          bson.document("encrypt") do
            bson["bsonType"] = "string"
            bson["algorithm"] = Mongo::ClientEncryption::ALGORITHM_DETERMINISTIC
            bson.array("keyId") do
              bson["0"] = key_id
            end
          end
        end
      end
    end
  end
end

private def ssn_encrypted_subtype?(doc : BSON) : Bool
  doc.each do |key, value, code, subtype|
    next unless key == "ssn"
    return false unless code.binary?
    return false unless value.is_a?(Bytes)
    if st = subtype
      return st.encrypted_bson?
    end
    return false
  end
  false
end

describe Mongo::AutoEncryption do
  it "reports crypt_shared path from the environment" do
    path = Mongo::AutoEncryption.crypt_shared_lib_path
    (path.nil? || path.is_a?(String)).should be_true
  end

  path = crypt_shared_lib_path
  if Mongo::ClientEncryption.lib_linked? && path
    it "inserts an encrypted field and finds it decrypted" do
      Mongo::SpecCluster.exclusive do
        uri = mongodb_uri_with(ENV["MONGODB_URI"], "serverSelectionTimeoutMS=5000")
        setup = Mongo::Client.new(uri)
        auto_client : Mongo::Client? = nil
        encryption : Mongo::ClientEncryption? = nil
        begin
          db = setup["csfle_auto"]
          db.command(Mongo::Commands::Drop, name: "people") rescue nil
          db.command(Mongo::Commands::Drop, name: "datakeys") rescue nil

          master_key = Random::Secure.random_bytes(Mongo::ClientEncryption::LOCAL_KEY_BYTES)
          kms = local_kms_providers(master_key)
          enc = Mongo::ClientEncryption.new(
            setup,
            key_vault_namespace: "csfle_auto.datakeys",
            kms_providers: kms
          )
          encryption = enc
          key_id = enc.create_data_key("local")
          enc.close
          encryption = nil

          shared = path
          unless shared
            raise "crypt_shared path missing"
          end
          extra = BSON.build do |bson|
            bson["cryptSharedLibPath"] = shared
            bson["cryptSharedLibRequired"] = true
          end
          auto = Mongo::Client.new(
            uri,
            auto_encryption: Mongo::AutoEncryption.new(
              key_vault_namespace: "csfle_auto.datakeys",
              kms_providers: kms,
              schema_map: fle1_schema_map("csfle_auto.people", key_id),
              extra_options: extra
            )
          )
          auto_client = auto

          coll = auto["csfle_auto"]["people"]
          inserted = coll.insert_one({ssn: "123-45-6789", name: "Ada"})
          ids = inserted.try(&.inserted_ids)
          unless ids && ids.size > 0
            raise "insert_one did not return an inserted id"
          end
          id = ids[0]

          found = coll.find_one({_id: id})
          unless found
            raise "find_one returned no document"
          end
          found["ssn"].should eq "123-45-6789"
          found["name"].should eq "Ada"

          raw = setup["csfle_auto"]["people"].find_one({_id: id})
          unless raw
            raise "raw find_one returned no document"
          end
          ssn_encrypted_subtype?(raw).should be_true
          raw["name"].should eq "Ada"

          db.command(Mongo::Commands::DropDatabase) rescue nil
        ensure
          encryption.try(&.close)
          auto_client.try(&.close)
          setup.close
        end
      end
    end
  else
    it "skips live auto-encryption when libmongocrypt or crypt_shared is missing" do
      (Mongo::ClientEncryption.lib_linked? && path).should be_false
    end
  end
end
