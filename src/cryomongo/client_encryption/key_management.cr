# Key-vault helpers and rewrap. These talk to MongoDB, not to cloud KMS.
# Local KMS only. Named local (`local:name`) is included.
class Mongo::ClientEncryption
  # Find one data key by UUID `_id`. Nil when missing.
  def get_key(id : BSON::Binary) : BSON?
    filter = BSON.build { |bson| bson["_id"] = id }
    @key_vault.find_one(filter)
  end

  # All data key documents. Cloned so cursor views do not die.
  def get_keys : Array(BSON)
    docs = [] of BSON
    @key_vault.find(BSON.new) do |doc|
      docs << BSON.new(doc.data)
    end
    docs
  end

  # Delete one data key by UUID `_id`.
  def delete_key(id : BSON::Binary) : Commands::Common::DeleteResult?
    filter = BSON.build { |bson| bson["_id"] = id }
    @key_vault.delete_one(filter)
  end

  # Add *key_alt_name* with `$addToSet`. Returns the document before the update.
  def add_key_alt_name(id : BSON::Binary, key_alt_name : String) : BSON?
    filter = BSON.build { |bson| bson["_id"] = id }
    update = BSON.build do |bson|
      bson.document("$addToSet") { bson["keyAltNames"] = key_alt_name }
    end
    @key_vault.find_one_and_update(filter, update)
  end

  # Remove *key_alt_name*. Empty `keyAltNames` is unset (`$$REMOVE`).
  def remove_key_alt_name(id : BSON::Binary, key_alt_name : String) : BSON?
    filter = BSON.build { |bson| bson["_id"] = id }
    stage = BSON.from_json({
      "$set" => {
        "keyAltNames" => {
          "$cond" => [
            {"$eq" => ["$keyAltNames", [key_alt_name]]},
            "$$REMOVE",
            {
              "$filter" => {
                "input" => "$keyAltNames",
                "cond"  => {"$ne" => ["$$this", key_alt_name]},
              },
            },
          ],
        },
      },
    }.to_json)
    @key_vault.find_one_and_update(filter, [stage])
  end

  # Find one data key by alt name.
  def get_key_by_alt_name(key_alt_name : String) : BSON?
    filter = BSON.build { |bson| bson["keyAltNames"] = key_alt_name }
    @key_vault.find_one(filter)
  end

  # Decrypt matching data keys and encrypt them again with *provider*.
  # Nil *provider* keeps each key's current master key (needs that KMS).
  def rewrap_many_data_key(filter : BSON, *, provider : String? = nil, master_key : BSON? = nil) : RewrapManyDataKeyResult
    if name = provider
      unless Kms.local_provider?(name)
        raise Mongo::Error::Crypt.new("rewrap_many_data_key only supports local KMS (including named local:name). Got #{name}.")
      end
    end
    @lock.synchronize do
      check_open
      ctx = new_ctx
      begin
        if name = provider
          set_master_key(ctx, name, master_key)
        end
        CBinary.with_bytes(filter.data) do |bin|
          CBinary.raise_ctx(ctx) unless LibMongoCrypt.ctx_rewrap_many_datakey_init(ctx, bin)
        end
        finalized = Context.run_rewrap(ctx, @key_vault)
        RewrapManyDataKeyResult.new(apply_rewrap_updates(finalized))
      ensure
        LibMongoCrypt.ctx_destroy(ctx)
      end
    end
  end

  # Finalize `v` is an array of `{_id, keyMaterial, masterKey}`. Empty → no write.
  # `updateDate` uses `$currentDate` (libmongocrypt header).
  private def apply_rewrap_updates(finalized : BSON) : Mongo::Bulk::WriteResult?
    models = [] of Mongo::Bulk::WriteModel
    finalized.each do |key, value, code|
      next unless key == "v"
      unless value.is_a?(BSON) && code.array?
        break
      end
      value.each do |_i, doc, _c|
        next unless doc.is_a?(BSON)
        id = uuid_binary(doc, "_id")
        update = BSON.build do |bson|
          bson.document("$set") do
            doc.each do |dk, dv, dc, ds|
              next if dk == "_id"
              append_cloned(bson, dk, dv, dc, ds)
            end
          end
          bson.document("$currentDate") { bson["updateDate"] = true }
        end
        q = BSON.build { |bson| bson["_id"] = id }
        models << Mongo::Bulk::UpdateOne.new(q, update)
      end
      break
    end
    return nil if models.empty?
    @key_vault.bulk_write(models, ordered: true)
  end
end
