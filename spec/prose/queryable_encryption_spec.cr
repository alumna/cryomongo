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

private def qe_encrypted_fields : BSON
  BSON.build do |bson|
    bson.array("fields") do
      bson.document("0") do
        bson["path"] = "ssn"
        bson["bsonType"] = "string"
        bson["keyId"] = nil
        bson.document("queries") do
          bson["queryType"] = "equality"
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

describe "Queryable Encryption" do
  it "stores encrypted_fields_map on AutoEncryption" do
    map = BSON.build do |bson|
      bson.document("db.coll") do
        bson.array("fields") { }
      end
    end
    opts = Mongo::AutoEncryption.new(
      key_vault_namespace: "db.keys",
      kms_providers: local_kms_providers(Bytes.new(Mongo::ClientEncryption::LOCAL_KEY_BYTES)),
      encrypted_fields_map: map
    )
    stored = opts.encrypted_fields_map
    stored.should_not be_nil
    if stored
      stored.has_key?("db.coll").should be_true
    end
    opts.schema_map.should be_nil
  end

  path = crypt_shared_lib_path
  if Mongo::ClientEncryption.lib_linked? && path
    # Server error Location6346402: encrypted collections need replica set or shard.
    if ENV["TOPOLOGY"]? == "standalone"
      pending "inserts and finds by an encrypted equality field (MongoDB does not allow Queryable Encryption collections on standalone)"
    else
      it "inserts and finds by an encrypted equality field" do
        Mongo::SpecCluster.exclusive do
          uri = mongodb_uri_with(ENV["MONGODB_URI"], "serverSelectionTimeoutMS=5000")
          setup = Mongo::Client.new(uri)
          auto_client : Mongo::Client? = nil
          encryption : Mongo::ClientEncryption? = nil
          begin
            db = setup["csfle_qe"]
            db.command(Mongo::Commands::DropDatabase) rescue nil

            master_key = Random::Secure.random_bytes(Mongo::ClientEncryption::LOCAL_KEY_BYTES)
            kms = local_kms_providers(master_key)
            enc = Mongo::ClientEncryption.new(
              setup,
              key_vault_namespace: "csfle_qe.datakeys",
              kms_providers: kms
            )
            encryption = enc

            _coll, filled = enc.create_encrypted_collection(
              db,
              "people",
              encrypted_fields: qe_encrypted_fields,
              kms_provider: "local"
            )
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
            ef_map = BSON.build do |bson|
              bson["csfle_qe.people"] = filled
            end
            auto = Mongo::Client.new(
              uri,
              auto_encryption: Mongo::AutoEncryption.new(
                key_vault_namespace: "csfle_qe.datakeys",
                kms_providers: kms,
                encrypted_fields_map: ef_map,
                extra_options: extra
              )
            )
            auto_client = auto

            coll = auto["csfle_qe"]["people"]
            inserted = coll.insert_one({ssn: "123-45-6789", name: "Ada"})
            ids = inserted.try(&.inserted_ids)
            unless ids && ids.size > 0
              raise "insert_one did not return an inserted id"
            end
            id = ids[0]

            found = coll.find_one({ssn: "123-45-6789"})
            unless found
              raise "equality find returned no document"
            end
            found["ssn"].should eq "123-45-6789"
            found["name"].should eq "Ada"
            found["_id"].should eq id

            raw = setup["csfle_qe"]["people"].find_one({_id: id})
            unless raw
              raise "raw find_one returned no document"
            end
            ssn_encrypted_subtype?(raw).should be_true
            raw["name"].should eq "Ada"

            coll.compact_structured_encryption_data

            db.command(Mongo::Commands::DropDatabase) rescue nil
          ensure
            encryption.try(&.close)
            auto_client.try(&.close)
            setup.close
          end
        end
      end
    end
  else
    it "skips live Queryable Encryption when libmongocrypt or crypt_shared is missing" do
      (Mongo::ClientEncryption.lib_linked? && path).should be_false
    end
  end
end
