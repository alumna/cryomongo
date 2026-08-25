require "./parse"

module Mongo::Unified::Operations
  # --- Helpers ---

  def json_to_bson_value(json : JSON::Any)
    BSON.from_json(%({"v": #{json.to_json}}))["v"]
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

  def parse_update_arg(update_json : JSON::Any)
    if update_json.as_a?
      update_json.as_a.map { |u| BSON.from_json(u.to_json) }
    else
      BSON.from_json(update_json.to_json)
    end
  end

  private def resolve_session(args : JSON::Any?, registry : Registry)
    if args && (session_id = args["session"]?.try(&.as_s))
      registry.sessions[session_id]?
    end
  end

  private def op_timeout_ms(args : JSON::Any?) : Int64?
    json_i64(args.try(&.["timeoutMS"]?))
  end

  private def op_timeout_mode(args : JSON::Any?) : Mongo::TimeoutMode?
    case args.try(&.["timeoutMode"]?).try(&.as_s?)
    when "cursorLifetime"
      Mongo::TimeoutMode::CursorLifetime
    when "iteration"
      Mongo::TimeoutMode::Iteration
    end
  end

  private def op_let(args : JSON::Any?) : BSON?
    args.try(&.["let"]?).try { |v| BSON.from_json(v.to_json) }
  end

  # --- Operation Implementations ---

  private def execute_fail_point(args, registry)
    raise "Missing arguments" unless args
    if client_name = args["client"]?.try(&.as_s)
      if client = registry.clients[client_name]?
        fail_point = BSON.from_json(args["failPoint"].to_json)
        name = fail_point["configureFailPoint"].as(String)
        mode = fail_point["mode"]
        data = fail_point["data"]?
        client.command(
          Mongo::Commands::ConfigureFailPoint,
          database: "admin",
          fail_point: name,
          mode: mode,
          options: {data: data}
        )
        # Official failPoint goes to the selected server (primary). Hello
        # handshake tests create the appName client after this op, and the URI
        # seed is often a secondary, so also arm the seed. Do not copy every
        # failPoint to all members: that marked every replica Unknown, retried
        # extra checkouts, and left failGetMoreAfterCursorCheckout on secondaries.
        arm_hello_failpoint_on_uri_seed(registry, client, name, mode, data.as?(BSON))
      end
    end
  end

  private def arm_hello_failpoint_on_uri_seed(registry, client, name, mode, data : BSON?) : Nil
    return unless hello_failpoint_for_new_client?(data, registry)
    seed = mongodb_seed_address(ENV["MONGODB_URI"]? || "")
    return unless seed
    return if seed == client.topology.primary_address
    ic = Mongo::Unified::Runner.shared_client
    server = ic.topology.snapshot.servers.find { |s| s.address == seed }
    return unless server
    return if server.type.unknown? || server.type.rs_ghost?
    begin
      ic.command(
        Mongo::Commands::ConfigureFailPoint,
        database: "admin",
        fail_point: name,
        mode: mode,
        options: {data: data},
        server_description: server
      )
    rescue
    end
  end

  # Hello failPoint for a client that does not exist yet (handshake tests).
  # If that appName client already exists, its monitors are live on every
  # member; a seed extra would emit more than one Unknown.
  private def hello_failpoint_for_new_client?(data : BSON?, registry : Registry) : Bool
    return false unless data
    app = data["appName"]?.try(&.as?(String)) || data["appname"]?.try(&.as?(String))
    return false unless app
    cmds = data["failCommands"]?
    return false unless cmds.is_a?(BSON)
    has_hello = false
    cmds.each do |_, value|
      next unless s = value.as?(String)
      n = s.downcase
      has_hello = true if n == "hello" || n == "ismaster"
    end
    return false unless has_hello
    registry.clients.each_value do |c|
      return false if c.options.appname == app
    end
    true
  end

  private def mongodb_seed_address(uri : String) : String?
    rest = uri.split("://", 2)[1]?
    return nil unless rest
    hostpart = rest.includes?('@') ? rest.split('@', 2)[1] : rest
    cut = hostpart.index('/') || hostpart.index('?')
    raw = cut ? hostpart[0, cut] : hostpart
    return nil if raw.empty?
    raw.includes?(':') ? raw.downcase : "#{raw.downcase}:27017"
  end

  private def execute_create_entities(args, runner)
    raise "Missing arguments" unless args
    entities = Array(Hash(String, EntityRequest)).from_json(args["entities"].to_json)
    runner.create_entities(entities)
  end

  private def execute_get_snapshot_time(op, registry)
    target = registry.resolve_target(op.object)
    if session = target.as?(Mongo::Session::ClientSession)
      if snap_time = session.snapshot_time
        if entity_name = op.saveResultAsEntity
          registry.entities[entity_name] = snap_time
        end
      else
        raise "TEST_FAILED: getSnapshotTime called but session.snapshot_time is nil"
      end
    end
  end

  private def execute_assert_session_dirty(args, registry)
    if args && (session_id = args["session"]?.try(&.as_s))
      if session_ent = registry.sessions[session_id]?
        raise "TEST_FAILED: Expected session #{session_id} to be dirty" unless session_ent.dirty
      end
    end
  end

  private def execute_assert_session_not_dirty(args, registry)
    if args && (session_id = args["session"]?.try(&.as_s))
      if session_ent = registry.sessions[session_id]?
        raise "TEST_FAILED: Expected session #{session_id} to not be dirty" if session_ent.dirty
      end
    end
  end

  private def execute_assert_same_lsid(args, registry)
    if args && (client_id = args["client"]?.try(&.as_s))
      events = registry.command_started_events[client_id]? || [] of Mongo::Monitoring::Commands::CommandStartedEvent
      raise "TEST_FAILED: Expected at least 2 events for client #{client_id}, got #{events.size}" if events.size < 2
      lsid1 = events[-2].command["lsid"]?
      lsid2 = events[-1].command["lsid"]?
      raise "TEST_FAILED: Expected same lsid on last two commands, got #{lsid1} and #{lsid2}" unless lsid1 && lsid2 && lsid1 == lsid2
    end
  end

  private def execute_assert_different_lsid(args, registry)
    if args && (client_id = args["client"]?.try(&.as_s))
      events = registry.command_started_events[client_id]? || [] of Mongo::Monitoring::Commands::CommandStartedEvent
      raise "TEST_FAILED: Expected at least 2 events for client #{client_id}, got #{events.size}" if events.size < 2
      lsid1 = events[-2].command["lsid"]?
      lsid2 = events[-1].command["lsid"]?
      raise "TEST_FAILED: Expected different lsid on last two commands, but got same: #{lsid1}" if lsid1 && lsid2 && lsid1 == lsid2
    end
  end

  private def execute_assert_session_pinned(args, registry)
    if args && (session_id = args["session"]?.try(&.as_s))
      if session_ent = registry.sessions[session_id]?
        unless session_ent.server_description
          raise "TEST_FAILED: Expected session #{session_id} to be pinned, txn=#{session_ent.transaction_state}"
        end
      end
    end
  end

  private def execute_assert_session_unpinned(args, registry)
    if args && (session_id = args["session"]?.try(&.as_s))
      if session_ent = registry.sessions[session_id]?
        if desc = session_ent.server_description
          raise "TEST_FAILED: Expected session #{session_id} to be unpinned, still pinned to #{desc.address} type=#{desc.type} txn=#{session_ent.transaction_state}"
        end
      end
    end
  end

  private def execute_assert_session_transaction_state(args, registry)
    if args && (session_id = args["session"]?.try(&.as_s))
      if session_ent = registry.sessions[session_id]?
        expected_state = args["state"].as_s
        actual_state = session_ent.transaction_state.to_s.downcase
        actual_state_mapped = case actual_state
                              when "none"       then "none"
                              when "starting"   then "starting"
                              when "inprogress" then "in_progress"
                              when "committed"  then "committed"
                              when "aborted"    then "aborted"
                              else                   actual_state
                              end
        if actual_state_mapped != expected_state
          raise "TEST_FAILED: Expected session transaction state #{expected_state}, got #{actual_state_mapped}"
        end
      end
    end
  end

  private def execute_targeted_fail_point(args, registry)
    if args && (session_id = args["session"]?.try(&.as_s))
      if session_ent = registry.sessions[session_id]?
        if server_desc = session_ent.server_description
          if fail_point_arg = args["failPoint"]?
            fail_point = BSON.from_json(fail_point_arg.to_json)
            session_ent.client.command(
              Mongo::Commands::ConfigureFailPoint,
              database: "admin",
              fail_point: fail_point["configureFailPoint"].as(String),
              mode: fail_point["mode"],
              options: {data: fail_point["data"]?},
              server_description: server_desc
            )
          end
        else
          raise "TEST_FAILED: Session #{session_id} is not pinned"
        end
      end
    end
  end

  private def execute_assert_collection_exists(args, internal_client)
    if args && (db_name = args["databaseName"]?.try(&.as_s)) && (coll_name = args["collectionName"]?.try(&.as_s))
      db = internal_client[db_name]
      colls = db.list_collections(filter: {name: coll_name}).to_a
      raise "TEST_FAILED: Expected collection #{coll_name} to exist" if colls.empty?
    end
  end

  private def execute_assert_collection_not_exists(args, internal_client)
    if args && (db_name = args["databaseName"]?.try(&.as_s)) && (coll_name = args["collectionName"]?.try(&.as_s))
      db = internal_client[db_name]
      colls = db.list_collections(filter: {name: coll_name}).to_a
      raise "TEST_FAILED: Expected collection #{coll_name} to NOT exist" unless colls.empty?
    end
  end

  private def execute_assert_index_exists(args, internal_client)
    if args && (db_name = args["databaseName"]?.try(&.as_s)) && (coll_name = args["collectionName"]?.try(&.as_s)) && (index_name = args["indexName"]?.try(&.as_s))
      db = internal_client[db_name]
      coll = db[coll_name]
      indexes = coll.list_indexes.to_a
      found = indexes.any? { |idx| index_name == idx["name"]?.try(&.as(String)) }
      raise "TEST_FAILED: Expected index #{index_name} to exist" unless found
    end
  end

  private def execute_assert_index_not_exists(args, internal_client)
    if args && (db_name = args["databaseName"]?.try(&.as_s)) && (coll_name = args["collectionName"]?.try(&.as_s)) && (index_name = args["indexName"]?.try(&.as_s))
      db = internal_client[db_name]
      coll = db[coll_name]
      begin
        indexes = coll.list_indexes.to_a
        found = indexes.any? { |idx| index_name == idx["name"]?.try(&.as(String)) }
        raise "TEST_FAILED: Expected index #{index_name} to NOT exist" if found
      rescue e : Mongo::Error::Command
        # If collection doesn't exist, index doesn't exist
      end
    end
  end

  private def execute_download(args, target)
    raise "Missing arguments" unless args
    id = json_to_bson_value(args["id"])
    stream = IO::Memory.new
    target.as(Mongo::GridFS::Bucket).download_to_stream(id, stream, timeout_ms: op_timeout_ms(args))
    stream.rewind.to_slice
  end

  private def execute_download_by_name(args, target)
    raise "Missing arguments" unless args
    filename = args["filename"].as_s
    revision = args["revision"]?.try { |v| v.as_i? || v.as_i64?.try(&.to_i32) } || -1
    stream = IO::Memory.new
    target.as(Mongo::GridFS::Bucket).download_to_stream_by_name(filename, stream, revision: revision, timeout_ms: op_timeout_ms(args))
    stream.rewind.to_slice
  end

  private def execute_create_collection(args, target, session)
    raise "Missing arguments" unless args
    coll_name = args["collection"].as_s
    view_on = args["viewOn"]?.try(&.as_s)
    pipeline = args["pipeline"]?.try(&.as_a).try { |stages| stages.map { |s| BSON.from_json(s.to_json) } }
    clustered = args["clusteredIndex"]?.try { |v| BSON.from_json(v.to_json) }
    timeseries = args["timeseries"]?.try { |v| BSON.from_json(v.to_json) }
    expire = args["expireAfterSeconds"]?.try { |v| v.as_i64? || v.as_i?.try(&.to_i64) }
    pre_post = args["changeStreamPreAndPostImages"]?.try { |v| BSON.from_json(v.to_json) }
    capped = args["capped"]?.try(&.as_bool)
    size = json_i64(args["size"]?)
    max = json_i64(args["max"]?)
    db = target.as(Mongo::Database)
    db.command(Mongo::Commands::Create, name: coll_name, session: session, timeout_ms: op_timeout_ms(args), options: {
      view_on:                           view_on,
      pipeline:                          pipeline,
      clustered_index:                   clustered,
      timeseries:                        timeseries,
      expire_after_seconds:              expire,
      change_stream_pre_and_post_images: pre_post,
      capped:                            capped,
      size:                              size,
      max:                               max,
    })
    db[coll_name]
  end

  private def execute_drop_collection(args, target, session)
    raise "Missing arguments" unless args
    coll_name = args["collection"].as_s
    target.as(Mongo::Database).command(Mongo::Commands::Drop, name: coll_name, session: session, options: NamedTuple.new) rescue nil
  end

  private def execute_drop_database(args, target, session)
    raise "Missing arguments" unless args
    name = args["database"].as_s
    target.as(Mongo::Client)[name].drop(session: session, timeout_ms: op_timeout_ms(args))
  end

  private def execute_create_index(args, target, session)
    raise "Missing arguments" unless args
    keys = BSON.from_json(args["keys"].to_json)
    opts_bson = BSON.new
    args.as_h.each do |k, v|
      next if k == "keys" || k == "session" || k == "rawData" || k == "timeoutMS" || k == "maxTimeMS" || k == "timeoutMode"
      opts_bson[k] = json_to_bson_value(v)
    end
    model = BSON.new({"keys" => keys, "options" => opts_bson})
    max_time_ms = args["maxTimeMS"]?.try(&.as_i64)
    target.as(Mongo::Collection).create_indexes([model], session: session, timeout_ms: op_timeout_ms(args), max_time_ms: max_time_ms)
  end

  private def execute_modify_collection(args, target, session)
    raise "Missing arguments" unless args
    coll_name = args["collection"].as_s
    validator = args["validator"]? ? json_to_bson_value(args["validator"]) : nil
    validation_level = args["validationLevel"]? ? args["validationLevel"].as_s : nil
    validation_action = args["validationAction"]? ? args["validationAction"].as_s : nil
    pre_post = args["changeStreamPreAndPostImages"]?.try { |v| BSON.from_json(v.to_json) }
    index = args["index"]?.try { |v| BSON.from_json(v.to_json) }

    target.as(Mongo::Database).command(
      Mongo::Commands::CollMod,
      collection: coll_name,
      session: session,
      options: {
        validator:                         validator,
        validation_level:                  validation_level,
        validation_action:                 validation_action,
        change_stream_pre_and_post_images: pre_post,
        index:                             index,
      }
    )
  end

  private def execute_insert_one(args, target, session)
    raise "Missing arguments" unless args
    doc = BSON.from_json(args["document"].to_json)
    doc["_id"] = BSON::ObjectId.new unless doc.has_key?("_id")
    comment = args["comment"]?
    bypass = args["bypassDocumentValidation"]?.try(&.as_bool)
    target.as(Mongo::Collection).insert_one(doc, comment: comment.try { |c| json_to_bson_value(c) }, bypass_document_validation: bypass, session: session, timeout_ms: op_timeout_ms(args))
    {"insertedId" => doc["_id"]}
  end

  private def execute_insert_many(args, target, session)
    raise "Missing arguments" unless args
    docs = args["documents"].as_a.map { |d| BSON.from_json(d.to_json) }
    ordered = args["ordered"]?.try(&.as_bool)
    ordered = true if ordered.nil?
    comment = args["comment"]?.try { |c| json_to_bson_value(c) }
    bypass = args["bypassDocumentValidation"]?.try(&.as_bool)
    target.as(Mongo::Collection).insert_many(docs, ordered: ordered, comment: comment, bypass_document_validation: bypass, session: session, timeout_ms: op_timeout_ms(args))
    inserted_ids = {} of String => BSON::Value
    docs.each_with_index do |doc, index|
      if id = doc["_id"]?
        inserted_ids[index.to_s] = id
      end
    end
    {"insertedCount" => docs.size, "insertedIds" => inserted_ids}
  end

  private def execute_update_one(args, target, session)
    raise "Missing arguments" unless args
    filter = BSON.from_json(args["filter"].to_json)
    update = parse_update_arg(args["update"])
    upsert = args["upsert"]?.try(&.as_bool) || false
    array_filters = args["arrayFilters"]?.try { |af| af.as_a.map { |f| BSON.from_json(f.to_json) } }
    collation = args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
    hint = args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) }
    comment = args["comment"]?.try { |c| json_to_bson_value(c) }
    sort = args["sort"]?.try { |s| BSON.from_json(s.to_json) }
    bypass = args["bypassDocumentValidation"]?.try(&.as_bool)
    result = target.as(Mongo::Collection).update_one(filter, update, upsert: upsert, array_filters: array_filters, collation: collation, hint: hint, comment: comment, sort: sort, bypass_document_validation: bypass, let: op_let(args), session: session, timeout_ms: op_timeout_ms(args))
    utf_update_result(result)
  end

  private def execute_update_many(args, target, session)
    raise "Missing arguments" unless args
    filter = BSON.from_json(args["filter"].to_json)
    update = parse_update_arg(args["update"])
    upsert = args["upsert"]?.try(&.as_bool) || false
    array_filters = args["arrayFilters"]?.try { |af| af.as_a.map { |f| BSON.from_json(f.to_json) } }
    collation = args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
    hint = args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) }
    comment = args["comment"]?.try { |c| json_to_bson_value(c) }
    bypass = args["bypassDocumentValidation"]?.try(&.as_bool)
    result = target.as(Mongo::Collection).update_many(filter, update, upsert: upsert, array_filters: array_filters, collation: collation, hint: hint, comment: comment, bypass_document_validation: bypass, let: op_let(args), session: session, timeout_ms: op_timeout_ms(args))
    utf_update_result(result)
  end

  private def execute_replace_one(args, target, session)
    raise "Missing arguments" unless args
    filter = BSON.from_json(args["filter"].to_json)
    replacement = BSON.from_json(args["replacement"].to_json)
    upsert = args["upsert"]?.try(&.as_bool) || false
    collation = args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
    hint = args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) }
    comment = args["comment"]?.try { |c| json_to_bson_value(c) }
    sort = args["sort"]?.try { |s| BSON.from_json(s.to_json) }
    bypass = args["bypassDocumentValidation"]?.try(&.as_bool)
    result = target.as(Mongo::Collection).replace_one(filter, replacement, upsert: upsert, collation: collation, hint: hint, comment: comment, sort: sort, bypass_document_validation: bypass, let: op_let(args), session: session, timeout_ms: op_timeout_ms(args))
    utf_update_result(result)
  end

  private def execute_delete_one(args, target, session)
    raise "Missing arguments" unless args
    filter = BSON.from_json(args["filter"].to_json)
    collation = args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
    hint = args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) }
    comment = args["comment"]?.try { |c| json_to_bson_value(c) }
    result = target.as(Mongo::Collection).delete_one(filter, collation: collation, hint: hint, comment: comment, let: op_let(args), session: session, timeout_ms: op_timeout_ms(args))
    {"deletedCount" => result.try(&.n) || 0}
  end

  private def execute_delete_many(args, target, session)
    raise "Missing arguments" unless args
    filter = BSON.from_json(args["filter"].to_json)
    collation = args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
    hint = args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) }
    comment = args["comment"]?.try { |c| json_to_bson_value(c) }
    result = target.as(Mongo::Collection).delete_many(filter, collation: collation, hint: hint, comment: comment, let: op_let(args), session: session, timeout_ms: op_timeout_ms(args))
    {"deletedCount" => result.try(&.n) || 0}
  end

  private def execute_find(args, target, session)
    if target.is_a?(Mongo::GridFS::Bucket)
      filter = args && args["filter"]? ? BSON.from_json(args["filter"].to_json) : BSON.new
      skip = args.try(&.["skip"]?).try(&.as_i)
      limit = args.try(&.["limit"]?).try(&.as_i)
      batch_size = args.try(&.["batchSize"]?).try(&.as_i)
      max_time_ms = args.try(&.["maxTimeMS"]?).try(&.as_i64) || args.try(&.["maxAwaitTimeMS"]?).try(&.as_i64)
      return target.find(filter, skip: skip, limit: limit, batch_size: batch_size, max_time_ms: max_time_ms, timeout_ms: op_timeout_ms(args)).to_a
    end
    find_cursor(args, target, session).to_a
  end

  private def execute_find_one(args, target, session)
    filter = args && args["filter"]? ? BSON.from_json(args["filter"].to_json) : BSON.new
    sort = args && args["sort"]? ? BSON.from_json(args["sort"].to_json) : nil
    skip = args && args["skip"]? ? args["skip"].as_i : nil
    collation = args && args["collation"]? ? Mongo::Collation.from_bson(BSON.from_json(args["collation"].to_json)) : nil
    hint = args && args["hint"]? ? (args["hint"].as_s? || BSON.from_json(args["hint"].to_json)) : nil
    target.as(Mongo::Collection).find_one(filter, sort: sort, skip: skip, collation: collation, hint: hint, let: op_let(args), session: session, timeout_ms: op_timeout_ms(args))
  end

  private def execute_list_collections(args, target, session)
    filter = args && args["filter"]? ? BSON.from_json(args["filter"].to_json) : nil
    batch_size = args.try(&.["batchSize"]?).try(&.as_i)
    target.as(Mongo::Database).list_collections(filter: filter, batch_size: batch_size, session: session, timeout_ms: op_timeout_ms(args), timeout_mode: op_timeout_mode(args)).to_a
  end

  private def execute_list_collection_names(args, target, session)
    filter = args && args["filter"]? ? BSON.from_json(args["filter"].to_json) : nil
    target.as(Mongo::Database).list_collections(filter: filter, name_only: true, session: session, timeout_ms: op_timeout_ms(args)).map { |c| c["name"].as(String) }.to_a
  end

  private def execute_list_databases(args, target, session)
    if res = target.as(Mongo::Client).list_databases(session: session, timeout_ms: op_timeout_ms(args))
      res.databases.try(&.map { |db| BSON.new({"name" => db.name, "sizeOnDisk" => db.size_on_disk, "empty" => db.empty}) }) || [] of BSON
    end
  end

  private def execute_list_database_names(args, target, session)
    if res = target.as(Mongo::Client).list_databases(name_only: true, session: session, timeout_ms: op_timeout_ms(args))
      res.databases.try(&.map(&.name)) || [] of String
    end
  end

  private def execute_list_indexes(args, target, session)
    batch_size = args.try(&.["batchSize"]?).try(&.as_i)
    target.as(Mongo::Collection).list_indexes(batch_size: batch_size, session: session, timeout_ms: op_timeout_ms(args), timeout_mode: op_timeout_mode(args)).try(&.to_a)
  end

  private def execute_list_index_names(args, target, session)
    target.as(Mongo::Collection).list_indexes(session: session, timeout_ms: op_timeout_ms(args)).try(&.map { |c| c["name"].as(String) }.to_a)
  end

  private def execute_run_command(args, target, session)
    raise "Missing arguments" unless args
    command_bson = BSON.from_json(args["command"].to_json)
    read_preference = args["readPreference"]?.try { |rp| Mongo::ReadPreference.from_bson(BSON.from_json(rp.to_json)) }
    target.as(Mongo::Database).run_command(command_bson, session: session, read_preference: read_preference, timeout_ms: op_timeout_ms(args))
  end

  private def execute_run_cursor_command(args, target, session)
    cursor = command_cursor(args, target, session)
    begin
      cursor.to_a
    ensure
      cursor.close
    end
  end

  private def execute_create_command_cursor(args, target, session, op, registry)
    cursor = command_cursor(args, target, session)
    if name = op.saveResultAsEntity
      registry.cursors[name] = cursor
    end
    cursor
  end

  private def command_cursor(args, target, session)
    raise "Missing arguments" unless args
    command_bson = BSON.from_json(args["command"].to_json)
    read_preference = args["readPreference"]?.try { |rp| Mongo::ReadPreference.from_bson(BSON.from_json(rp.to_json)) }
    batch_size = args["batchSize"]?.try(&.as_i)
    comment = args["comment"]?.try { |c| json_to_bson_value(c) }
    max_time_ms = json_i64(args["maxTimeMS"]?) || json_i64(args["maxAwaitTimeMS"]?)
    cursor_type = case args["cursorType"]?.try(&.as_s?)
                  when "tailable"
                    Mongo::CursorType::Tailable
                  when "tailableAwait"
                    Mongo::CursorType::TailableAwait
                  when "nonTailable"
                    Mongo::CursorType::NonTailable
                  end
    target.as(Mongo::Database).run_cursor_command(
      command_bson,
      session: session,
      read_preference: read_preference,
      timeout_ms: op_timeout_ms(args),
      timeout_mode: op_timeout_mode(args),
      cursor_type: cursor_type,
      batch_size: batch_size,
      comment: comment,
      max_time_ms: max_time_ms,
    )
  end

  private def execute_create_change_stream(args, target, session)
    pipeline = args && args["pipeline"]? ? args["pipeline"].as_a.map { |p| BSON.from_json(p.to_json) } : [] of BSON
    batch_size = args.try(&.["batchSize"]?).try(&.as_i)
    max_await = args.try(&.["maxAwaitTimeMS"]?).try(&.as_i64)
    full_document = args.try(&.["fullDocument"]?).try(&.as_s)
    full_before = args.try(&.["fullDocumentBeforeChange"]?).try(&.as_s)
    show_expanded = args.try(&.["showExpandedEvents"]?).try(&.as_bool)
    comment = args.try(&.["comment"]?).try { |c| json_to_bson_value(c) }
    timeout_ms = op_timeout_ms(args)
    if target.is_a?(Mongo::Collection)
      target.watch(pipeline, batch_size: batch_size, max_await_time_ms: max_await, full_document: full_document, full_document_before_change: full_before, show_expanded_events: show_expanded, comment: comment, session: session, timeout_ms: timeout_ms)
    elsif target.is_a?(Mongo::Database)
      target.watch(pipeline, batch_size: batch_size, max_await_time_ms: max_await, full_document: full_document, full_document_before_change: full_before, show_expanded_events: show_expanded, comment: comment, session: session, timeout_ms: timeout_ms)
    elsif target.is_a?(Mongo::Client)
      target.watch(pipeline, batch_size: batch_size, max_await_time_ms: max_await, full_document: full_document, full_document_before_change: full_before, show_expanded_events: show_expanded, comment: comment, session: session, timeout_ms: timeout_ms)
    end
  end

  private def execute_aggregate(args, target, session)
    raise "Missing arguments" unless args
    pipeline = args["pipeline"].as_a.map { |p| BSON.from_json(p.to_json) }
    allow_disk_use = args["allowDiskUse"]?.try(&.as_bool)
    collation = args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
    batch_size = args["batchSize"]?.try(&.as_i)
    max_time_ms = args["maxTimeMS"]?.try(&.as_i64)
    comment = args["comment"]?.try { |c| json_to_bson_value(c) }
    bypass = args["bypassDocumentValidation"]?.try(&.as_bool)

    timeout_ms = op_timeout_ms(args)
    timeout_mode = op_timeout_mode(args)
    max_await = args["maxAwaitTimeMS"]?.try(&.as_i64)
    cursor = if target.is_a?(Mongo::Database)
               target.aggregate(pipeline, allow_disk_use: allow_disk_use, collation: collation, batch_size: batch_size, max_time_ms: max_time_ms, comment: comment, bypass_document_validation: bypass, let: op_let(args), session: session, timeout_ms: timeout_ms, timeout_mode: timeout_mode, max_await_time_ms: max_await)
             else
               target.as(Mongo::Collection).aggregate(pipeline, allow_disk_use: allow_disk_use, collation: collation, batch_size: batch_size, max_time_ms: max_time_ms, comment: comment, bypass_document_validation: bypass, let: op_let(args), session: session, timeout_ms: timeout_ms, timeout_mode: timeout_mode, max_await_time_ms: max_await)
             end
    cursor ? cursor.to_a : [] of BSON
  end

  private def execute_count_documents(args, target, session)
    filter = BSON.new
    collation = nil; skip = nil; limit = nil

    if args
      filter = BSON.from_json(args["filter"].to_json) if args["filter"]?
      collation = args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
      skip = args["skip"]?.try(&.as_i)
      limit = args["limit"]?.try(&.as_i)
    end
    comment = args.try(&.["comment"]?).try { |c| json_to_bson_value(c) }
    target.as(Mongo::Collection).count_documents(filter, collation: collation, skip: skip, limit: limit, comment: comment, session: session, timeout_ms: op_timeout_ms(args))
  end

  private def execute_count(args, target, session)
    filter = BSON.new
    collation = nil; skip = nil; limit = nil; hint = nil

    if args
      filter = BSON.from_json(args["filter"].to_json) if args["filter"]?
      collation = args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
      skip = args["skip"]?.try { |v| v.as_i? || v.as_i64?.try(&.to_i32) }
      limit = args["limit"]?.try { |v| v.as_i? || v.as_i64?.try(&.to_i32) }
      hint = args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) }
    end
    comment = args.try(&.["comment"]?).try { |c| json_to_bson_value(c) }
    target.as(Mongo::Collection).count(filter, collation: collation, skip: skip, limit: limit, hint: hint, comment: comment, session: session, timeout_ms: op_timeout_ms(args))
  end

  private def execute_estimated_document_count(args, target, session)
    max_time_ms = args.try(&.["maxTimeMS"]?).try(&.as_i64)
    comment = args.try(&.["comment"]?).try { |c| json_to_bson_value(c) }
    target.as(Mongo::Collection).estimated_document_count(max_time_ms: max_time_ms, comment: comment, session: session, timeout_ms: op_timeout_ms(args))
  end

  private def execute_distinct(args, target, session)
    raise "Missing arguments" unless args
    key = args["fieldName"].as_s
    filter = args["filter"]? ? BSON.from_json(args["filter"].to_json) : nil
    collation = args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
    hint = args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) }
    comment = args["comment"]?.try { |c| json_to_bson_value(c) }
    target.as(Mongo::Collection).distinct(key, filter: filter, collation: collation, hint: hint, comment: comment, session: session, timeout_ms: op_timeout_ms(args))
  end

  private def execute_map_reduce(args, target, session)
    raise "Missing arguments" unless args
    map = json_to_bson_value(args["map"])
    reduce = json_to_bson_value(args["reduce"])
    output = BSON.from_json(args["out"].to_json)
    target.as(Mongo::Collection).map_reduce(map, reduce, output: output, session: session, timeout_ms: op_timeout_ms(args))
  end

  private def execute_find_one_and_delete(args, target, session)
    raise "Missing arguments" unless args
    filter = BSON.from_json(args["filter"].to_json)
    sort = args["sort"]? ? BSON.from_json(args["sort"].to_json) : nil
    collation = args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
    hint = args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) }
    max_time_ms = args["maxTimeMS"]?.try(&.as_i64)
    comment = args["comment"]?.try { |c| json_to_bson_value(c) }
    bypass = args["bypassDocumentValidation"]?.try(&.as_bool)
    target.as(Mongo::Collection).find_one_and_delete(filter, sort: sort, collation: collation, hint: hint, max_time_ms: max_time_ms, comment: comment, bypass_document_validation: bypass, let: op_let(args), session: session, timeout_ms: op_timeout_ms(args))
  end

  private def execute_find_one_and_replace(args, target, session)
    raise "Missing arguments" unless args
    filter = BSON.from_json(args["filter"].to_json)
    replacement = BSON.from_json(args["replacement"].to_json)
    sort = args["sort"]? ? BSON.from_json(args["sort"].to_json) : nil
    upsert = args["upsert"]?.try(&.as_bool) || false
    new_doc = args["returnDocument"]?.try(&.as_s) == "After"
    collation = args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
    hint = args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) }
    max_time_ms = args["maxTimeMS"]?.try(&.as_i64)
    comment = args["comment"]?.try { |c| json_to_bson_value(c) }
    bypass = args["bypassDocumentValidation"]?.try(&.as_bool)
    target.as(Mongo::Collection).find_one_and_replace(filter, replacement, sort: sort, upsert: upsert, new: new_doc, collation: collation, hint: hint, max_time_ms: max_time_ms, comment: comment, bypass_document_validation: bypass, let: op_let(args), session: session, timeout_ms: op_timeout_ms(args))
  end

  private def execute_find_one_and_update(args, target, session)
    raise "Missing arguments" unless args
    filter = BSON.from_json(args["filter"].to_json)
    update = parse_update_arg(args["update"])
    sort = args["sort"]? ? BSON.from_json(args["sort"].to_json) : nil
    upsert = args["upsert"]?.try(&.as_bool) || false
    new_doc = args["returnDocument"]?.try(&.as_s) == "After"
    array_filters = args["arrayFilters"]?.try { |af| af.as_a.map { |f| BSON.from_json(f.to_json) } }
    collation = args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
    hint = args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) }
    max_time_ms = args["maxTimeMS"]?.try(&.as_i64)
    comment = args["comment"]?.try { |c| json_to_bson_value(c) }
    bypass = args["bypassDocumentValidation"]?.try(&.as_bool)
    target.as(Mongo::Collection).find_one_and_update(filter, update, sort: sort, upsert: upsert, new: new_doc, array_filters: array_filters, collation: collation, hint: hint, max_time_ms: max_time_ms, comment: comment, bypass_document_validation: bypass, let: op_let(args), session: session, timeout_ms: op_timeout_ms(args))
  end

  private def execute_bulk_write(args, target, session)
    raise "Missing arguments" unless args
    requests = args["requests"].as_a.map do |req_any|
      req = req_any.as_h
      if req["insertOne"]?
        req_args = req["insertOne"]
        doc = BSON.from_json(req_args["document"].to_json)
        Mongo::Bulk::InsertOne.new(doc).as(Mongo::Bulk::WriteModel)
      elsif req["updateOne"]?
        req_args = req["updateOne"]
        f = BSON.from_json(req_args["filter"].to_json)
        u = parse_update_arg(req_args["update"])
        upsert = req_args["upsert"]?.try(&.as_bool)
        collation = req_args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
        hint = req_args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) }
        arrayFilters = req_args["arrayFilters"]?.try { |af| af.as_a.map { |f_el| BSON.from_json(f_el.to_json) } }
        sort = req_args["sort"]?.try { |s| BSON.from_json(s.to_json) }
        Mongo::Bulk::UpdateOne.new(f, u, upsert: upsert, collation: collation, hint: hint, array_filters: arrayFilters, sort: sort).as(Mongo::Bulk::WriteModel)
      elsif req["updateMany"]?
        req_args = req["updateMany"]
        f = BSON.from_json(req_args["filter"].to_json)
        u = parse_update_arg(req_args["update"])
        upsert = req_args["upsert"]?.try(&.as_bool)
        collation = req_args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
        hint = req_args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) }
        arrayFilters = req_args["arrayFilters"]?.try { |af| af.as_a.map { |f_el| BSON.from_json(f_el.to_json) } }
        Mongo::Bulk::UpdateMany.new(f, u, upsert: upsert, collation: collation, hint: hint, array_filters: arrayFilters).as(Mongo::Bulk::WriteModel)
      elsif req["replaceOne"]?
        req_args = req["replaceOne"]
        f = BSON.from_json(req_args["filter"].to_json)
        r = BSON.from_json(req_args["replacement"].to_json)
        upsert = req_args["upsert"]?.try(&.as_bool)
        collation = req_args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
        hint = req_args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) }
        sort = req_args["sort"]?.try { |s| BSON.from_json(s.to_json) }
        Mongo::Bulk::ReplaceOne.new(f, r, upsert: upsert, collation: collation, hint: hint, sort: sort).as(Mongo::Bulk::WriteModel)
      elsif req["deleteOne"]?
        req_args = req["deleteOne"]
        f = BSON.from_json(req_args["filter"].to_json)
        collation = req_args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
        hint = req_args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) }
        Mongo::Bulk::DeleteOne.new(f, collation: collation, hint: hint).as(Mongo::Bulk::WriteModel)
      elsif req["deleteMany"]?
        req_args = req["deleteMany"]
        f = BSON.from_json(req_args["filter"].to_json)
        collation = req_args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
        hint = req_args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) }
        Mongo::Bulk::DeleteMany.new(f, collation: collation, hint: hint).as(Mongo::Bulk::WriteModel)
      else
        raise "Unsupported bulkWrite request type"
      end
    end
    ordered = args["ordered"]?.try(&.as_bool)
    ordered = true if ordered.nil?
    comment = args["comment"]?.try { |c| json_to_bson_value(c) }
    bypass = args["bypassDocumentValidation"]?.try(&.as_bool)

    result = target.as(Mongo::Collection).bulk_write(requests, ordered: ordered, comment: comment, bypass_document_validation: bypass, let: op_let(args), session: session, timeout_ms: op_timeout_ms(args))
    {
      "insertedCount" => result.n_inserted,
      "matchedCount"  => result.n_matched,
      "modifiedCount" => result.n_modified,
      "deletedCount"  => result.n_removed,
      "upsertedCount" => result.n_upserted,
      "upsertedIds"   => result.upserted.each_with_object({} of String => BSON::Value?) { |u, h| h[u.index.to_s] = u._id },
    }
  end

  private def execute_client_bulk_write(args, target, session)
    raise "Missing arguments" unless args
    models = args["models"].as_a.map { |model_any| parse_client_bulk_model(model_any) }
    ordered = args["ordered"]?.try(&.as_bool)
    ordered = true if ordered.nil?
    verbose = args["verboseResults"]?.try(&.as_bool) || false
    comment = args["comment"]?.try { |c| json_to_bson_value(c) }
    bypass = args["bypassDocumentValidation"]?.try(&.as_bool)
    wc = args["writeConcern"]?.try { |v| Parse.write_concern(v) }
    result = target.as(Mongo::Client).bulk_write(
      models,
      ordered: ordered,
      comment: comment,
      bypass_document_validation: bypass,
      let: op_let(args),
      write_concern: wc,
      verbose_results: verbose,
      session: session,
      timeout_ms: op_timeout_ms(args),
    )
    utf_client_bulk_result(result)
  end

  private def parse_client_bulk_model(model_any : JSON::Any) : Mongo::ClientBulk::WriteModel
    req = model_any.as_h
    if req["insertOne"]?
      req_args = req["insertOne"]
      ns = req_args["namespace"].as_s
      doc = BSON.from_json(req_args["document"].to_json)
      Mongo::ClientBulk::InsertOne.new(ns, doc)
    elsif req["updateOne"]?
      req_args = req["updateOne"]
      Mongo::ClientBulk::UpdateOne.new(
        req_args["namespace"].as_s,
        BSON.from_json(req_args["filter"].to_json),
        parse_update_arg(req_args["update"]),
        upsert: req_args["upsert"]?.try(&.as_bool),
        collation: req_args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) },
        hint: req_args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) },
        array_filters: req_args["arrayFilters"]?.try { |af| af.as_a.map { |f_el| BSON.from_json(f_el.to_json) } },
        sort: req_args["sort"]?.try { |s| BSON.from_json(s.to_json) },
      )
    elsif req["updateMany"]?
      req_args = req["updateMany"]
      Mongo::ClientBulk::UpdateMany.new(
        req_args["namespace"].as_s,
        BSON.from_json(req_args["filter"].to_json),
        parse_update_arg(req_args["update"]),
        upsert: req_args["upsert"]?.try(&.as_bool),
        collation: req_args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) },
        hint: req_args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) },
        array_filters: req_args["arrayFilters"]?.try { |af| af.as_a.map { |f_el| BSON.from_json(f_el.to_json) } },
      )
    elsif req["replaceOne"]?
      req_args = req["replaceOne"]
      Mongo::ClientBulk::ReplaceOne.new(
        req_args["namespace"].as_s,
        BSON.from_json(req_args["filter"].to_json),
        BSON.from_json(req_args["replacement"].to_json),
        upsert: req_args["upsert"]?.try(&.as_bool),
        collation: req_args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) },
        hint: req_args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) },
        sort: req_args["sort"]?.try { |s| BSON.from_json(s.to_json) },
      )
    elsif req["deleteOne"]?
      req_args = req["deleteOne"]
      Mongo::ClientBulk::DeleteOne.new(
        req_args["namespace"].as_s,
        BSON.from_json(req_args["filter"].to_json),
        collation: req_args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) },
        hint: req_args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) },
      )
    elsif req["deleteMany"]?
      req_args = req["deleteMany"]
      Mongo::ClientBulk::DeleteMany.new(
        req_args["namespace"].as_s,
        BSON.from_json(req_args["filter"].to_json),
        collation: req_args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) },
        hint: req_args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) },
      )
    else
      raise "Unsupported clientBulkWrite model type"
    end
  end

  def utf_client_bulk_result(result : Mongo::ClientBulk::WriteResult)
    hash = {
      "insertedCount" => result.inserted_count,
      "upsertedCount" => result.upserted_count,
      "matchedCount"  => result.matched_count,
      "modifiedCount" => result.modified_count,
      "deletedCount"  => result.deleted_count,
    } of String => Int32 | Hash(String, Hash(String, BSON::Value | Int32))
    if inserts = result.insert_results
      mapped = {} of String => Hash(String, BSON::Value | Int32)
      inserts.each { |idx, row| mapped[idx.to_s] = {"insertedId" => row.inserted_id} of String => BSON::Value | Int32 }
      hash["insertResults"] = mapped
    end
    if updates = result.update_results
      mapped = {} of String => Hash(String, BSON::Value | Int32)
      updates.each do |idx, row|
        row_h = {
          "matchedCount"  => row.matched_count,
          "modifiedCount" => row.modified_count,
        } of String => BSON::Value | Int32
        if uid = row.upserted_id
          row_h["upsertedId"] = uid
        end
        mapped[idx.to_s] = row_h
      end
      hash["updateResults"] = mapped
    end
    if deletes = result.delete_results
      mapped = {} of String => Hash(String, BSON::Value | Int32)
      deletes.each { |idx, row| mapped[idx.to_s] = {"deletedCount" => row.deleted_count} of String => BSON::Value | Int32 }
      hash["deleteResults"] = mapped
    end
    hash
  end

  def utf_client_bulk_write_errors(error : Mongo::Error::ClientBulkWrite)
    mapped = {} of String => Hash(String, Int32 | String)
    error.write_errors.each do |idx, we|
      mapped[idx.to_s] = {"code" => we.code, "message" => we.message} of String => Int32 | String
    end
    mapped
  end

  def utf_client_bulk_write_concern_errors(error : Mongo::Error::ClientBulkWrite)
    error.write_concern_errors.map do |wce|
      {"code" => wce.code, "message" => wce.message} of String => Int32 | String
    end
  end

  private def utf_update_result(result)
    upserted = result.try(&.upserted)
    upserted_count = upserted.try(&.size) || 0
    matched = (result.try(&.n) || 0) - upserted_count
    {
      "matchedCount"  => matched,
      "modifiedCount" => result.try(&.n_modified) || 0,
      "upsertedCount" => upserted_count,
      "upsertedId"    => upserted.try(&.first?).try(&._id),
    }
  end

  private def execute_start_transaction(args, target)
    rc = args.try(&.["readConcern"]?).try { |v| Parse.read_concern(v) }
    wc = args.try(&.["writeConcern"]?).try { |v| Parse.write_concern(v) }
    rp = args.try(&.["readPreference"]?).try { |v| Parse.read_preference(v) }
    max_commit_time_ms = args.try(&.["maxCommitTimeMS"]?).try(&.as_i64)

    if target && target.is_a?(Mongo::Session::ClientSession)
      target.start_transaction(
        read_concern: rc,
        write_concern: wc,
        read_preference: rp,
        max_commit_time_ms: max_commit_time_ms
      )
    end
  end

  private def execute_commit_transaction(args, target)
    if target && target.is_a?(Mongo::Session::ClientSession)
      wc = args.try(&.["writeConcern"]?).try { |v| Parse.write_concern(v) }
      target.commit_transaction(write_concern: wc, timeout_ms: op_timeout_ms(args))
    end
  end

  private def execute_abort_transaction(args, target)
    if target && target.is_a?(Mongo::Session::ClientSession)
      wc = args.try(&.["writeConcern"]?).try { |v| Parse.write_concern(v) }
      target.abort_transaction(write_concern: wc, timeout_ms: op_timeout_ms(args))
    end
  end

  private def execute_end_session(args, target)
    if target && target.is_a?(Mongo::Session::ClientSession)
      target.end
    end
  end

  private def execute_with_transaction(args, target, registry, internal_client, runner)
    if args && (callback_ops = args["callback"]?.try(&.as_a))
      rc = args["readConcern"]?.try { |v| Parse.read_concern(v) }
      wc = args["writeConcern"]?.try { |v| Parse.write_concern(v) }
      rp = args["readPreference"]?.try { |v| Parse.read_preference(v) }
      max_commit_time_ms = args["maxCommitTimeMS"]?.try(&.as_i64)

      if target && target.is_a?(Mongo::Session::ClientSession)
        target.with_transaction(
          timeout_ms: op_timeout_ms(args),
          read_concern: rc,
          write_concern: wc,
          read_preference: rp,
          max_commit_time_ms: max_commit_time_ms
        ) do
          callback_ops.each do |cb_op|
            op_obj = Operation.from_json(cb_op.to_json)
            execute(op_obj, registry, internal_client, runner, raise_operation_errors: true)
          end
        end
      end
    end
  end

  private def execute_run_on_thread(args, registry, internal_client, runner)
    if args && (thread_id = args["thread"]?.try(&.as_s)) && (op_json = args["operation"]?)
      op = Operation.from_json(op_json.to_json)
      if channel = registry.threads[thread_id]?
        spawn do
          begin
            execute(op, registry, internal_client, runner)
            channel.send(nil)
          rescue e : Exception
            channel.send(e)
          end
        end
      end
    end
  end

  private def execute_wait_for_thread(args, registry)
    if args && (thread_id = args["thread"]?.try(&.as_s))
      if channel = registry.threads[thread_id]?
        if err = channel.receive
          raise err
        end
      end
    end
  end

  private def execute_wait(args)
    ms = args.try(&.["ms"]?).try { |v| v.as_i64? || v.as_i?.try(&.to_i64) } || 0_i64
    sleep ms.milliseconds if ms > 0
  end

  private def execute_record_topology_description(args, registry)
    raise "Missing arguments" unless args
    client_id = args["client"].as_s
    id = args["id"].as_s
    client = registry.clients[client_id]?
    raise Exception.new("TEST_FAILED: client #{client_id} not found") unless client
    registry.topology_descriptions[id] = client.topology.snapshot
  end

  private def execute_assert_topology_type(args, registry)
    raise "Missing arguments" unless args
    id = args["topologyDescription"].as_s
    expected = args["topologyType"].as_s
    description = registry.topology_descriptions[id]?
    raise Exception.new("TEST_FAILED: topologyDescription #{id} not found") unless description
    actual = description.type.to_s
    unless actual == expected
      raise Exception.new("TEST_FAILED: topology type expected #{expected}, got #{actual}")
    end
  end

  private def execute_wait_for_primary_change(args, registry)
    raise "Missing arguments" unless args
    client_id = args["client"].as_s
    prior_id = args["priorTopologyDescription"].as_s
    timeout_ms = json_i64(args["timeoutMS"]?) || 10_000_i64
    client = registry.clients[client_id]?
    raise Exception.new("TEST_FAILED: client #{client_id} not found") unless client
    prior = registry.topology_descriptions[prior_id]?
    raise Exception.new("TEST_FAILED: topologyDescription #{prior_id} not found") unless prior
    prior_primary = prior.primary_address
    deadline = Time.instant + timeout_ms.milliseconds
    loop do
      current_primary = client.topology.primary_address
      if current_primary && current_primary != prior_primary && replica_set_member_writable?(current_primary)
        return
      end
      if Time.instant >= deadline
        raise Exception.new("TEST_FAILED: waitForPrimaryChange timed out (prior=#{prior_primary.inspect}, current=#{current_primary.inspect})")
      end
      sleep 50.milliseconds
    end
  end

  # Shared client hello, not the test client: ping/hello would show up in expectEvents.
  # Address change alone is not enough: the new primary may still reject writes
  # (catch-up), and retryable insertMany then fails rediscover-quickly expectEvents.
  private def replica_set_member_writable?(address : String) : Bool
    ic = Mongo::Unified::Runner.shared_client
    server = ic.topology.snapshot.servers.find { |s| s.address == address }
    return false unless server
    begin
      result = ic.command(Mongo::Commands::Hello, server_description: server)
      return false unless result.is_a?(Mongo::Commands::Hello::Result)
      result.isWritablePrimary || result.ismaster
    rescue
      false
    end
  end

  private def execute_close(args, target)
    case target
    when Mongo::Client
      target.close
    when Mongo::Cursor
      target.close(timeout_ms: op_timeout_ms(args))
    end
  end

  private def execute_assert_number_connections_checked_out(args, registry)
    raise "Missing arguments" unless args
    client_id = args["client"].as_s
    expected = args["connections"].as_i? || args["connections"].as_i64.to_i
    client = registry.clients[client_id]?
    raise "TEST_FAILED: client #{client_id} not found" unless client
    actual = client.checked_out_count
    unless actual == expected
      raise Exception.new("TEST_FAILED: expected #{expected} connections checked out, got #{actual}")
    end
  end

  private def execute_append_metadata(args, target)
    client = target.as?(Mongo::Client)
    raise "TEST_FAILED: appendMetadata target is not a client" unless client
    info = args.try(&.["driverInfoOptions"]?) || args
    raise "Missing driverInfoOptions" unless info
    name = info["name"].as_s
    version = info["version"]?.try(&.as_s?)
    platform = info["platform"]?.try(&.as_s?)
    client.append_metadata(name, version, platform)
  end

  private def execute_wait_for_event(args, registry)
    raise "Missing arguments" unless args
    client_id = args["client"].as_s
    event = args["event"]
    count = args["count"].as_i
    deadline = Time.instant + 10.seconds
    loop do
      return if count_matching_events(registry, client_id, event) >= count
      if Time.instant >= deadline
        actual = count_matching_events(registry, client_id, event)
        raise Exception.new("TEST_FAILED: waitForEvent timed out for #{event.inspect} (got #{actual}, want #{count})")
      end
      sleep 50.milliseconds
    end
  end

  private def execute_assert_event_count(args, registry)
    raise "Missing arguments" unless args
    client_id = args["client"].as_s
    event = args["event"]
    count = args["count"].as_i
    actual = count_matching_events(registry, client_id, event)
    unless actual == count
      raise Exception.new("TEST_FAILED: assertEventCount expected #{count} of #{event.inspect}, got #{actual}")
    end
  end

  private def count_matching_events(registry : Registry, client_id : String, event : JSON::Any) : Int32
    cmap = registry.snapshot_cmap_events(client_id)
    sdam = registry.snapshot_sdam_events(client_id)
    command = registry.snapshot_command_events(client_id)
    if event["poolCreatedEvent"]?
      return cmap.count { |e|
        e.is_a?(Mongo::Monitoring::CMAP::PoolCreatedEvent)
      }
    end
    if event["poolReadyEvent"]?
      return cmap.count { |e|
        e.is_a?(Mongo::Monitoring::CMAP::PoolReadyEvent)
      }
    end
    if event["poolClearedEvent"]?
      return cmap.count { |e|
        e.is_a?(Mongo::Monitoring::CMAP::PoolClearedEvent)
      }
    end
    if event["poolClosedEvent"]?
      return cmap.count { |e|
        e.is_a?(Mongo::Monitoring::CMAP::PoolClosedEvent)
      }
    end
    if event["connectionCreatedEvent"]?
      return cmap.count { |e|
        e.is_a?(Mongo::Monitoring::CMAP::ConnectionCreatedEvent)
      }
    end
    if event["connectionReadyEvent"]?
      return cmap.count { |e|
        e.is_a?(Mongo::Monitoring::CMAP::ConnectionReadyEvent)
      }
    end
    if event["connectionClosedEvent"]?
      return cmap.count { |e|
        e.is_a?(Mongo::Monitoring::CMAP::ConnectionClosedEvent)
      }
    end
    if event["connectionCheckOutStartedEvent"]?
      return cmap.count { |e|
        e.is_a?(Mongo::Monitoring::CMAP::ConnectionCheckOutStartedEvent)
      }
    end
    if event["connectionCheckedOutEvent"]?
      return cmap.count { |e|
        e.is_a?(Mongo::Monitoring::CMAP::ConnectionCheckedOutEvent)
      }
    end
    if event["connectionCheckOutFailedEvent"]?
      return cmap.count { |e|
        e.is_a?(Mongo::Monitoring::CMAP::ConnectionCheckOutFailedEvent)
      }
    end
    if event["connectionCheckedInEvent"]?
      return cmap.count { |e|
        e.is_a?(Mongo::Monitoring::CMAP::ConnectionCheckedInEvent)
      }
    end
    if event["topologyDescriptionChangedEvent"]?
      return sdam.count { |e|
        e.is_a?(Mongo::Monitoring::SDAM::TopologyDescriptionChangedEvent)
      }
    end
    if event["topologyOpeningEvent"]?
      return sdam.count { |e|
        e.is_a?(Mongo::Monitoring::SDAM::TopologyOpeningEvent)
      }
    end
    if event["topologyClosedEvent"]?
      return sdam.count { |e|
        e.is_a?(Mongo::Monitoring::SDAM::TopologyClosedEvent)
      }
    end
    if expected = event["serverHeartbeatStartedEvent"]?
      return sdam.count { |e|
        e.is_a?(Mongo::Monitoring::SDAM::ServerHeartbeatStartedEvent) && Matcher.heartbeat_awaited?(e.awaited, expected)
      }
    end
    if expected = event["serverHeartbeatSucceededEvent"]?
      return sdam.count { |e|
        e.is_a?(Mongo::Monitoring::SDAM::ServerHeartbeatSucceededEvent) && Matcher.heartbeat_awaited?(e.awaited, expected)
      }
    end
    if expected = event["serverHeartbeatFailedEvent"]?
      return sdam.count { |e|
        e.is_a?(Mongo::Monitoring::SDAM::ServerHeartbeatFailedEvent) && Matcher.heartbeat_awaited?(e.awaited, expected)
      }
    end
    if expected = event["serverDescriptionChangedEvent"]?
      return sdam.count { |e|
        match_server_description_changed?(e, expected)
      }
    end
    if expected = event["commandStartedEvent"]?
      return command.count { |e|
        e.is_a?(Mongo::Monitoring::Commands::CommandStartedEvent) &&
          command_name_match?(e, expected)
      }
    end
    if expected = event["commandSucceededEvent"]?
      return command.count { |e|
        e.is_a?(Mongo::Monitoring::Commands::CommandSucceededEvent) &&
          command_name_match?(e, expected)
      }
    end
    if expected = event["commandFailedEvent"]?
      return command.count { |e|
        e.is_a?(Mongo::Monitoring::Commands::CommandFailedEvent) &&
          command_name_match?(e, expected)
      }
    end
    0
  end

  private def command_name_match?(event, expected : JSON::Any) : Bool
    if name = expected["commandName"]?.try(&.as_s?)
      event.command_name == name
    else
      true
    end
  end

  private def match_server_description_changed?(event, expected : JSON::Any) : Bool
    return false unless event.is_a?(Mongo::Monitoring::SDAM::ServerDescriptionChangedEvent)
    if new_desc = expected["newDescription"]?
      if type = new_desc["type"]?.try(&.as_s?)
        return event.new_description.type.to_s == type
      end
    end
    true
  end

  private def execute_upload(args, target)
    raise "Missing arguments" unless args
    bucket = target.as(Mongo::GridFS::Bucket)
    filename = args["filename"].as_s
    source = IO::Memory.new(hex_bytes(args["source"]))
    id = args["id"]? ? json_to_bson_value(args["id"]) : nil
    chunk = args["chunkSizeBytes"]?.try { |v| v.as_i? || v.as_i64?.try(&.to_i32) }
    metadata = args["metadata"]?.try { |m| BSON.from_json(m.to_json) }
    bucket.upload_from_stream(filename, source, id: id, chunk_size_bytes: chunk, metadata: metadata, timeout_ms: op_timeout_ms(args))
  end

  private def execute_gridfs_delete(args, target)
    raise "Missing arguments" unless args
    id = json_to_bson_value(args["id"])
    target.as(Mongo::GridFS::Bucket).delete(id, timeout_ms: op_timeout_ms(args))
  end

  private def execute_gridfs_rename(args, target)
    raise "Missing arguments" unless args
    id = json_to_bson_value(args["id"])
    new_name = args["newFilename"].as_s
    target.as(Mongo::GridFS::Bucket).rename(id, new_name, timeout_ms: op_timeout_ms(args))
  end

  private def execute_gridfs_delete_by_name(args, target)
    raise "Missing arguments" unless args
    filename = args["filename"].as_s
    target.as(Mongo::GridFS::Bucket).delete_by_name(filename, timeout_ms: op_timeout_ms(args))
  end

  private def execute_gridfs_rename_by_name(args, target)
    raise "Missing arguments" unless args
    filename = args["filename"].as_s
    new_name = args["newFilename"].as_s
    target.as(Mongo::GridFS::Bucket).rename_by_name(filename, new_name, timeout_ms: op_timeout_ms(args))
  end

  private def execute_gridfs_drop(args, target)
    target.as(Mongo::GridFS::Bucket).drop(timeout_ms: op_timeout_ms(args))
  end

  private def execute_rename_collection(args, target, session)
    raise "Missing arguments" unless args
    coll = target.as(Mongo::Collection)
    to = args["to"].as_s
    drop_target = args["dropTarget"]?.try(&.as_bool)
    coll.database.command(
      Mongo::Commands::RenameCollection,
      collection: coll.name,
      to: "#{coll.database.name}.#{to}",
      session: session,
      options: {
        drop_target: drop_target,
      }
    )
  end

  private def execute_iterate_until_document_or_error(target)
    cursor = target.as(Mongo::Cursor)
    doc = cursor.next
    if doc.is_a?(Iterator::Stop)
      raise Mongo::Error.new("Cursor exhausted")
    end
    doc
  end

  private def execute_iterate_once(target)
    target.as(Mongo::Cursor).try_next
  end

  private def execute_create_find_cursor(args, target, session, op, registry)
    cursor = find_cursor(args, target, session)
    if name = op.saveResultAsEntity
      registry.cursors[name] = cursor
    end
    cursor
  end

  private def find_cursor(args, target, session)
    filter = BSON.new
    sort = nil; skip = nil; limit = nil; batch_size = nil
    collation = nil; hint = nil; allow_disk_use = nil; max_time_ms = nil
    comment = nil; tailable = nil; await_data = nil
    projection = nil; max = nil; min = nil
    return_key = nil; show_record_id = nil
    if args
      filter = BSON.from_json(args["filter"].to_json) if args["filter"]?
      sort = BSON.from_json(args["sort"].to_json) if args["sort"]?
      skip = args["skip"]?.try(&.as_i)
      limit = args["limit"]?.try(&.as_i)
      batch_size = args["batchSize"]?.try(&.as_i)
      collation = args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
      hint = args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) }
      allow_disk_use = args["allowDiskUse"]?.try(&.as_bool)
      max_time_ms = args["maxTimeMS"]?.try(&.as_i64) || args["maxAwaitTimeMS"]?.try(&.as_i64)
      comment = args["comment"]?.try { |c| json_to_bson_value(c) }
      tailable = args["tailable"]?.try(&.as_bool)
      await_data = args["awaitData"]?.try(&.as_bool)
      projection = BSON.from_json(args["projection"].to_json) if args["projection"]?
      max = BSON.from_json(args["max"].to_json) if args["max"]?
      min = BSON.from_json(args["min"].to_json) if args["min"]?
      return_key = args["returnKey"]?.try(&.as_bool)
      show_record_id = args["showRecordId"]?.try(&.as_bool)
      case args["cursorType"]?.try(&.as_s?)
      when "tailable"
        tailable = true
      when "tailableAwait"
        tailable = true
        await_data = true
      end
    end
    target.as(Mongo::Collection).find(filter, sort: sort, skip: skip, limit: limit, batch_size: batch_size, collation: collation, hint: hint, allow_disk_use: allow_disk_use, max_time_ms: max_time_ms, comment: comment, let: op_let(args), session: session, tailable: tailable, await_data: await_data, timeout_ms: op_timeout_ms(args), timeout_mode: op_timeout_mode(args), projection: projection, max: max, min: min, return_key: return_key, show_record_id: show_record_id)
  end

  private def execute_drop_index(args, target, session)
    raise "Missing arguments" unless args
    name = args["name"].as_s
    target.as(Mongo::Collection).drop_index(name, session: session, timeout_ms: op_timeout_ms(args))
  end

  private def execute_drop_indexes(args, target, session)
    target.as(Mongo::Collection).drop_indexes(session: session, timeout_ms: op_timeout_ms(args))
  end

  private def hex_bytes(json : JSON::Any) : Bytes
    if (h = json.as_h?) && (hex = h["$$hexBytes"]?)
      hex.as_s.hexbytes
    elsif s = json.as_s?
      s.hexbytes
    else
      raise "Missing GridFS source bytes"
    end
  end
end
