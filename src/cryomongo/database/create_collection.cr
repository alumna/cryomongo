class Mongo::Database
  # Clustered index for Queryable Encryption state collections (ESC / ECOC).
  QE_CLUSTERED_INDEX = BSON.build do |bson|
    bson.document("key") do
      bson["_id"] = 1
    end
    bson["unique"] = true
  end

  # Wire 21 is MongoDB 7.0, the first Queryable Encryption server.
  QE_MIN_WIRE_VERSION = 21
  QE_WIRE_ERROR       = "Driver support of Queryable Encryption is incompatible with server. Upgrade server to use Queryable Encryption."

  # Create a collection. When *encrypted_fields* is set, or the namespace is in
  # AutoEncryption `encryptedFieldsMap`, also create the ESC and ECOC clustered
  # collections and the `__safeContent__` index (Queryable Encryption).
  def create_collection(
    name : String,
    *,
    encrypted_fields : BSON? = nil,
    session : Session::ClientSession? = nil,
    timeout_ms : Int64? = nil,
  ) : Mongo::Collection
    ef = encrypted_fields || @client.encrypted_fields_for("#{@name}.#{name}")
    if found = ef
      create_queryable_collection(name, found, session, timeout_ms)
    else
      self.command(Commands::Create, name: name, session: session, timeout_ms: timeout_ms)
    end
    self[name]
  end

  # Spec CreateCollection helper for Queryable Encryption. Do not look up
  # encryptedFieldsMap again for ESC / ECOC (those names are not in the map).
  private def create_queryable_collection(
    name : String,
    encrypted_fields : BSON,
    session : Session::ClientSession?,
    timeout_ms : Int64?,
  ) : Nil
    check_queryable_encryption_wire
    clustered = {clustered_index: QE_CLUSTERED_INDEX}
    self.command(Commands::Create, name: qe_state_collection(encrypted_fields, "escCollection", name, "esc"), session: session, timeout_ms: timeout_ms, options: clustered)
    self.command(Commands::Create, name: qe_state_collection(encrypted_fields, "ecocCollection", name, "ecoc"), session: session, timeout_ms: timeout_ms, options: clustered)
    self.command(Commands::Create, name: name, session: session, timeout_ms: timeout_ms, options: {
      encrypted_fields: encrypted_fields,
    })
    self[name].create_index({__safeContent__: 1}, session: session, timeout_ms: timeout_ms)
  end

  # Drop ESC and ECOC for a Queryable Encryption collection. Ignores missing
  # namespaces (code 26). The data collection is dropped by the caller.
  # :nodoc:
  def drop_queryable_encryption_state(
    name : String,
    encrypted_fields : BSON,
    session : Session::ClientSession? = nil,
    timeout_ms : Int64? = nil,
    deadline : Mongo::Deadline? = nil,
  ) : Nil
    drop_ignore_missing(qe_state_collection(encrypted_fields, "escCollection", name, "esc"), session, timeout_ms, deadline)
    drop_ignore_missing(qe_state_collection(encrypted_fields, "ecocCollection", name, "ecoc"), session, timeout_ms, deadline)
  end

  private def drop_ignore_missing(
    name : String,
    session : Session::ClientSession?,
    timeout_ms : Int64?,
    deadline : Mongo::Deadline?,
  ) : Nil
    self.command(Commands::Drop, name: name, session: session, timeout_ms: timeout_ms, deadline: deadline)
  rescue e : Mongo::Error::Command
    raise e unless e.code == 26
  end

  private def qe_state_collection(encrypted_fields : BSON, field : String, name : String, suffix : String) : String
    encrypted_fields.each do |key, value, _code|
      next unless key == field
      if s = value.as?(String)
        return s unless s.empty?
      end
      break
    end
    "enxcol_.#{name}.#{suffix}"
  end

  # Load-balanced descriptions have no wire version (no monitors). This driver
  # is MongoDB 8.0 only, so skip the check there.
  private def check_queryable_encryption_wire : Nil
    topology = @client.topology
    return if topology.type.load_balanced?
    wire = writable_max_wire_version
    if wire == 0
      @client.command(Commands::Ping)
      wire = writable_max_wire_version
    end
    if wire > 0 && wire < QE_MIN_WIRE_VERSION
      raise Mongo::Error.new(QE_WIRE_ERROR)
    end
  end

  private def writable_max_wire_version : Int32
    max = 0
    @client.topology.servers.each do |server|
      t = server.type
      next unless t.standalone? || t.rs_primary? || t.mongos? || t.load_balancer?
      w = server.max_wire_version
      max = w if w > max
    end
    max
  end
end
