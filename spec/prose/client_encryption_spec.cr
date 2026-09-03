require "../spec_helper"
require "random/secure"

private def local_kms_providers(master_key : Bytes) : BSON
  BSON.build do |bson|
    bson.document("local") do
      bson["key"] = BSON::Binary.new(:generic, master_key)
    end
  end
end

describe Mongo::ClientEncryption do
  it "reports whether libmongocrypt was linked" do
    Mongo::ClientEncryption.lib_linked?.should be_a(Bool)
  end

  if Mongo::ClientEncryption.lib_linked?
    it "creates a local data key, encrypts a string, and decrypts it" do
      Mongo::SpecCluster.exclusive do
        client = Mongo::Client.new(mongodb_uri_with(ENV["MONGODB_URI"], "serverSelectionTimeoutMS=5000"))
        encryption : Mongo::ClientEncryption? = nil
        begin
          db = client["csfle_explicit"]
          db.command(Mongo::Commands::Drop, name: "datakeys") rescue nil

          master_key = Random::Secure.random_bytes(Mongo::ClientEncryption::LOCAL_KEY_BYTES)
          enc = Mongo::ClientEncryption.new(
            client,
            key_vault_namespace: "csfle_explicit.datakeys",
            kms_providers: local_kms_providers(master_key)
          )
          encryption = enc

          key_id = enc.create_data_key("local", key_alt_names: ["wave21"])
          key_id.subtype.should eq BSON::Binary::SubType::UUID
          key_id.data.size.should eq 16

          plaintext = "secret text"
          encrypted = enc.encrypt(
            plaintext,
            algorithm: Mongo::ClientEncryption::ALGORITHM_RANDOM,
            key_id: key_id
          )
          encrypted.subtype.should eq BSON::Binary::SubType::EncryptedBSON
          encrypted.data.should_not eq plaintext.to_slice

          decrypted = enc.decrypt(encrypted)
          decrypted.should eq plaintext

          by_name = enc.encrypt(
            plaintext,
            algorithm: Mongo::ClientEncryption::ALGORITHM_DETERMINISTIC,
            key_alt_name: "wave21"
          )
          by_name.subtype.should eq BSON::Binary::SubType::EncryptedBSON
          again = enc.encrypt(
            plaintext,
            algorithm: Mongo::ClientEncryption::ALGORITHM_DETERMINISTIC,
            key_alt_name: "wave21"
          )
          again.data.should eq by_name.data
          enc.decrypt(by_name).should eq plaintext

          db.command(Mongo::Commands::DropDatabase) rescue nil
        ensure
          encryption.try(&.close)
          client.close
        end
      end
    end

    it "raises when the local master key is not 96 bytes" do
      Mongo::SpecCluster.exclusive do
        client = Mongo::Client.new(mongodb_uri_with(ENV["MONGODB_URI"], "serverSelectionTimeoutMS=5000"))
        begin
          expect_raises(Mongo::Error::Crypt, /96 bytes/) do
            Mongo::ClientEncryption.new(
              client,
              key_vault_namespace: "csfle_explicit.datakeys",
              kms_providers: local_kms_providers(Bytes.new(32))
            )
          end
        ensure
          client.close
        end
      end
    end
  else
    it "raises a clear error when libmongocrypt was not linked" do
      Mongo::SpecCluster.exclusive do
        client = Mongo::Client.new(mongodb_uri_with(ENV["MONGODB_URI"], "serverSelectionTimeoutMS=5000"))
        begin
          expect_raises(Mongo::Error::Crypt, /libmongocrypt/) do
            Mongo::ClientEncryption.new(
              client,
              key_vault_namespace: "csfle_explicit.datakeys",
              kms_providers: local_kms_providers(Bytes.new(96))
            )
          end
        ensure
          client.close
        end
      end
    end
  end
end
