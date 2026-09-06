class Mongo::Client
  # Queryable Encryption `encryptedFields` for *namespace* (`db.coll`), or nil.
  # Clone is owned by the caller. Not on the command hot path.
  # :nodoc:
  def encrypted_fields_for(namespace : String) : BSON?
    if auto = @auto_encryption
      auto.encrypted_fields_for(namespace)
    else
      nil
    end
  end
end
