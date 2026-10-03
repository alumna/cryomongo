# createEncryptedCollection: fill null keyId values, then CreateCollection.
# Does not change AutoEncryption on existing clients (spec).
# :nodoc:
class Mongo::ClientEncryption
  # Create a Queryable Encryption collection. Generates a data key for each
  # field whose `keyId` is null. Returns the collection and the filled
  # `encryptedFields`. Local KMS only (`masterKey` is not used).
  #
  # Configure auto-encryption on a new client with that `encryptedFields` map
  # after this call. This method does not update existing auto-encryption.
  def create_encrypted_collection(
    database : Mongo::Database,
    name : String,
    *,
    encrypted_fields : BSON,
    kms_provider : String,
  ) : {Mongo::Collection, BSON}
    unless Kms.local_provider?(kms_provider)
      raise Mongo::Error::Crypt.new("create_encrypted_collection only supports local KMS (including named local:name). Got #{kms_provider}.")
    end
    filled = fill_null_key_ids(encrypted_fields, kms_provider)
    begin
      database.create_collection(name, encrypted_fields: filled)
    rescue ex
      raise Mongo::Error::EncryptedCollection.new(
        ex.message || "create_encrypted_collection failed.",
        encrypted_fields: filled,
        cause: ex
      )
    end
    {database[name], filled}
  end

  # Replace null keyId with a new data key. Keep already-set keyIds.
  # On data-key error, raise EncryptedCollection with the fields filled so far.
  private def fill_null_key_ids(encrypted_fields : BSON, kms_provider : String) : BSON
    fields = encrypted_fields["fields"]?
    unless fields.is_a?(BSON)
      return BSON.new(encrypted_fields.data)
    end

    filled_fields = [] of BSON
    begin
      fields.each do |_key, value, _code|
        unless value.is_a?(BSON)
          filled_fields << BSON.new
          next
        end
        filled_fields << assign_field_key_id(value, kms_provider)
      end
    rescue ex
      partial = rebuild_encrypted_fields(encrypted_fields, filled_fields, fields)
      raise Mongo::Error::EncryptedCollection.new(
        ex.message || "create_encrypted_collection failed to create a data key.",
        encrypted_fields: partial,
        cause: ex
      )
    end
    rebuild_encrypted_fields(encrypted_fields, filled_fields, nil)
  end

  # Clone one field document. Create a data key when keyId is null.
  private def assign_field_key_id(field : BSON, kms_provider : String) : BSON
    new_key : BSON::Binary? = nil
    field.each do |key, value, _code|
      next unless key == "keyId"
      if value.nil?
        new_key = create_data_key(kms_provider)
      end
      break
    end
    BSON.build do |builder|
      field.each do |key, value, code, subtype|
        if key == "keyId"
          if assigned = new_key
            builder[key] = assigned
            next
          end
        end
        append_cloned(builder, key, value, code, subtype)
      end
    end
  end

  # Copy EF and replace `fields`. *remaining* is the original array when a
  # later key failed: keep original documents for indexes not yet filled.
  private def rebuild_encrypted_fields(original : BSON, filled : Array(BSON), remaining : BSON?) : BSON
    BSON.build do |builder|
      original.each do |key, value, code, subtype|
        if key == "fields"
          builder.array("fields") do
            index = 0
            filled.each do |field|
              builder[index.to_s] = field
              index += 1
            end
            if rest = remaining
              skipped = filled.size
              pos = 0
              rest.each do |_k, field, _c|
                if pos >= skipped
                  if field.is_a?(BSON)
                    builder[index.to_s] = BSON.new(field.data)
                  else
                    builder[index.to_s] = field
                  end
                  index += 1
                end
                pos += 1
              end
            end
          end
        else
          append_cloned(builder, key, value, code, subtype)
        end
      end
    end
  end

  # Copy a BSON value. Arrays stay arrays. Binary keeps its subtype. Clone Bytes.
  private def append_cloned(builder : BSON::Builder, key : String, value, code : BSON::Element, subtype : BSON::Binary::SubType?) : Nil
    case value
    when BSON
      if code.array?
        builder.append_array(key, value)
      else
        builder[key] = value
      end
    when Bytes
      st = subtype || BSON::Binary::SubType::Generic
      builder[key] = BSON::Binary.new(st, value.clone)
    else
      builder[key] = value
    end
  end
end
