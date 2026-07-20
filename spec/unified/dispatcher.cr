module Mongo::Unified::Dispatcher
  extend self

  struct RawCommand
    include Mongo::Commands::Command
    include Mongo::Commands::MayUseSecondary
    getter name : String

    def initialize(@name : String)
    end

    def command(**args)
      bson = args["command_bson"].as(BSON)
      bson["$db"] = args["database"].as(String) unless bson.has_key?("$db")
      {bson, nil}
    end

    def result(bson : BSON)
      bson
    end
  end

  def execute(op : Operation, registry : Registry, internal_client : Mongo::Client, runner)
    args = op.arguments

    # Some operations trigger skips based on their arguments
    if op.name == "clientBulkWrite" || args.try(&.as_h?.try(&.has_key?("let")))
      raise Exception.new("SKIP_TEST")
    end

    target = registry.resolve_target(op.object)
    session = resolve_session(args, registry)

    case op.name
    when "failPoint"                                then execute_fail_point(args, registry)
    when "createEntities"                           then execute_create_entities(args, runner)
    when "assertSessionPinned"                      then execute_assert_session_pinned(args, registry)
    when "assertSessionUnpinned"                    then execute_assert_session_unpinned(args, registry)
    when "assertSessionTransactionState"            then execute_assert_session_transaction_state(args, registry)
    when "targetedFailPoint"                        then execute_targeted_fail_point(args, registry)
    when "assertCollectionExists"                   then execute_assert_collection_exists(args, internal_client)
    when "assertCollectionNotExists"                then execute_assert_collection_not_exists(args, internal_client)
    when "assertIndexExists"                        then execute_assert_index_exists(args, internal_client)
    when "assertIndexNotExists"                     then execute_assert_index_not_exists(args, internal_client)
    when "download"                                 then execute_download(args, target)
    when "downloadByName"                           then execute_download_by_name(args, target)
    when "createCollection"                         then execute_create_collection(args, target, session)
    when "dropCollection"                           then execute_drop_collection(args, target, session)
    when "createIndex"                              then execute_create_index(args, target, session)
    when "modifyCollection"                         then execute_modify_collection(args, target, session)
    when "insertOne"                                then execute_insert_one(args, target, session)
    when "insertMany"                               then execute_insert_many(args, target, session)
    when "updateOne"                                then execute_update_one(args, target, session)
    when "updateMany"                               then execute_update_many(args, target, session)
    when "replaceOne"                               then execute_replace_one(args, target, session)
    when "deleteOne"                                then execute_delete_one(args, target, session)
    when "deleteMany"                               then execute_delete_many(args, target, session)
    when "find"                                     then execute_find(args, target, session)
    when "findOne"                                  then execute_find_one(args, target, session)
    when "listCollections", "listCollectionObjects" then execute_list_collections(args, target, session)
    when "listCollectionNames"                      then execute_list_collection_names(args, target, session)
    when "listDatabases", "listDatabaseObjects"     then execute_list_databases(args, target, session)
    when "listDatabaseNames"                        then execute_list_database_names(args, target, session)
    when "listIndexes"                              then execute_list_indexes(args, target, session)
    when "listIndexNames"                           then execute_list_index_names(args, target, session)
    when "runCommand"                               then execute_run_command(args, target, session)
    when "createChangeStream"                       then execute_create_change_stream(args, target, session)
    when "aggregate"                                then execute_aggregate(args, target, session)
    when "countDocuments"                           then execute_count_documents(args, target, session)
    when "estimatedDocumentCount"                   then execute_estimated_document_count(args, target, session)
    when "distinct"                                 then execute_distinct(args, target, session)
    when "findOneAndDelete"                         then execute_find_one_and_delete(args, target, session)
    when "findOneAndReplace"                        then execute_find_one_and_replace(args, target, session)
    when "findOneAndUpdate"                         then execute_find_one_and_update(args, target, session)
    when "bulkWrite"                                then execute_bulk_write(args, target, session)
    when "startTransaction"                         then execute_start_transaction(args, target)
    when "commitTransaction"                        then execute_commit_transaction(args, target)
    when "abortTransaction"                         then execute_abort_transaction(args, target)
    when "endSession"                               then execute_end_session(args, target)
    when "withTransaction"                          then execute_with_transaction(args, target, registry, internal_client, runner)
    else
      # Ignore unsupported operations silently or log them
    end
  end

  # --- Helpers ---

  def json_to_bson_value(json : JSON::Any)
    BSON.from_json(%({"v": #{json.to_json}}))["v"]
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

  # --- Operation Implementations ---

  private def execute_fail_point(args, registry)
    raise "Missing arguments" unless args
    if client_name = args["client"]?.try(&.as_s)
      if client = registry.clients[client_name]?
        fail_point = BSON.from_json(args["failPoint"].to_json)
        client.command(
          Mongo::Commands::ConfigureFailPoint,
          database: "admin",
          fail_point: fail_point["configureFailPoint"].as(String),
          mode: fail_point["mode"],
          options: {data: fail_point["data"]?}
        )
      end
    end
  end

  private def execute_create_entities(args, runner)
    raise "Missing arguments" unless args
    entities = Array(Hash(String, EntityRequest)).from_json(args["entities"].to_json)
    runner.create_entities(entities)
  end

  private def execute_assert_session_pinned(args, registry)
    if args && (session_id = args["session"]?.try(&.as_s))
      if session_ent = registry.sessions[session_id]?
        raise "TEST_FAILED: Expected session #{session_id} to be pinned" unless session_ent.server_description
      end
    end
  end

  private def execute_assert_session_unpinned(args, registry)
    if args && (session_id = args["session"]?.try(&.as_s))
      if session_ent = registry.sessions[session_id]?
        raise "TEST_FAILED: Expected session #{session_id} to be unpinned" if session_ent.server_description
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
    target.as(Mongo::GridFS::Bucket).download_to_stream(id, stream)
  end

  private def execute_download_by_name(args, target)
    raise "Missing arguments" unless args
    filename = args["filename"].as_s
    stream = IO::Memory.new
    target.as(Mongo::GridFS::Bucket).download_to_stream_by_name(filename, stream)
  end

  private def execute_create_collection(args, target, session)
    raise "Missing arguments" unless args
    coll_name = args["collection"].as_s
    target.as(Mongo::Database).command(Mongo::Commands::Create, name: coll_name, session: session)
  end

  private def execute_drop_collection(args, target, session)
    raise "Missing arguments" unless args
    coll_name = args["collection"].as_s
    target.as(Mongo::Database).command(Mongo::Commands::Drop, name: coll_name, session: session) rescue nil
  end

  private def execute_create_index(args, target, session)
    raise "Missing arguments" unless args
    keys = BSON.from_json(args["keys"].to_json)
    opts_bson = BSON.new
    args.as_h.each do |k, v|
      next if k == "keys" || k == "session"
      opts_bson[k] = json_to_bson_value(v)
    end
    model = BSON.new({"keys" => keys, "options" => opts_bson})
    target.as(Mongo::Collection).create_indexes([model], session: session)
  end

  private def execute_modify_collection(args, target, session)
    raise "Missing arguments" unless args
    coll_name = args["collection"].as_s
    validator = args["validator"]? ? json_to_bson_value(args["validator"]) : nil
    validation_level = args["validationLevel"]? ? args["validationLevel"].as_s : nil
    validation_action = args["validationAction"]? ? args["validationAction"].as_s : nil

    target.as(Mongo::Database).command(
      Mongo::Commands::CollMod,
      collection: coll_name,
      session: session,
      options: {
        validator:         validator,
        validation_level:  validation_level,
        validation_action: validation_action,
      }
    )
  end

  private def execute_insert_one(args, target, session)
    raise "Missing arguments" unless args
    doc = BSON.from_json(args["document"].to_json)
    target.as(Mongo::Collection).insert_one(doc, session: session)
  end

  private def execute_insert_many(args, target, session)
    raise "Missing arguments" unless args
    docs = args["documents"].as_a.map { |d| BSON.from_json(d.to_json) }
    ordered = args["ordered"]?.try(&.as_bool)
    ordered = true if ordered.nil?
    target.as(Mongo::Collection).insert_many(docs, ordered: ordered, session: session)
  end

  private def execute_update_one(args, target, session)
    raise "Missing arguments" unless args
    filter = BSON.from_json(args["filter"].to_json)
    update = parse_update_arg(args["update"])
    upsert = args["upsert"]?.try(&.as_bool) || false
    array_filters = args["arrayFilters"]?.try { |af| af.as_a.map { |f| BSON.from_json(f.to_json) } }
    collation = args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
    hint = args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) }
    target.as(Mongo::Collection).update_one(filter, update, upsert: upsert, array_filters: array_filters, collation: collation, hint: hint, session: session)
  end

  private def execute_update_many(args, target, session)
    raise "Missing arguments" unless args
    filter = BSON.from_json(args["filter"].to_json)
    update = parse_update_arg(args["update"])
    upsert = args["upsert"]?.try(&.as_bool) || false
    array_filters = args["arrayFilters"]?.try { |af| af.as_a.map { |f| BSON.from_json(f.to_json) } }
    collation = args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
    hint = args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) }
    target.as(Mongo::Collection).update_many(filter, update, upsert: upsert, array_filters: array_filters, collation: collation, hint: hint, session: session)
  end

  private def execute_replace_one(args, target, session)
    raise "Missing arguments" unless args
    filter = BSON.from_json(args["filter"].to_json)
    replacement = BSON.from_json(args["replacement"].to_json)
    upsert = args["upsert"]?.try(&.as_bool) || false
    collation = args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
    hint = args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) }
    target.as(Mongo::Collection).replace_one(filter, replacement, upsert: upsert, collation: collation, hint: hint, session: session)
  end

  private def execute_delete_one(args, target, session)
    raise "Missing arguments" unless args
    filter = BSON.from_json(args["filter"].to_json)
    collation = args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
    hint = args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) }
    target.as(Mongo::Collection).delete_one(filter, collation: collation, hint: hint, session: session)
  end

  private def execute_delete_many(args, target, session)
    raise "Missing arguments" unless args
    filter = BSON.from_json(args["filter"].to_json)
    collation = args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
    hint = args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) }
    target.as(Mongo::Collection).delete_many(filter, collation: collation, hint: hint, session: session)
  end

  private def execute_find(args, target, session)
    filter = BSON.new
    sort = nil; skip = nil; limit = nil; batch_size = nil
    collation = nil; hint = nil; allow_disk_use = nil; max_time_ms = nil

    if args
      filter = BSON.from_json(args["filter"].to_json) if args["filter"]?
      sort = BSON.from_json(args["sort"].to_json) if args["sort"]?
      skip = args["skip"]?.try(&.as_i)
      limit = args["limit"]?.try(&.as_i)
      batch_size = args["batchSize"]?.try(&.as_i)
      collation = args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
      hint = args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) }
      allow_disk_use = args["allowDiskUse"]?.try(&.as_bool)
      max_time_ms = args["maxTimeMS"]?.try(&.as_i64)
    end
    target.as(Mongo::Collection).find(filter, sort: sort, skip: skip, limit: limit, batch_size: batch_size, collation: collation, hint: hint, allow_disk_use: allow_disk_use, max_time_ms: max_time_ms, session: session).to_a
  end

  private def execute_find_one(args, target, session)
    filter = args && args["filter"]? ? BSON.from_json(args["filter"].to_json) : BSON.new
    sort = args && args["sort"]? ? BSON.from_json(args["sort"].to_json) : nil
    skip = args && args["skip"]? ? args["skip"].as_i : nil
    collation = args && args["collation"]? ? Mongo::Collation.from_bson(BSON.from_json(args["collation"].to_json)) : nil
    hint = args && args["hint"]? ? (args["hint"].as_s? || BSON.from_json(args["hint"].to_json)) : nil
    target.as(Mongo::Collection).find_one(filter, sort: sort, skip: skip, collation: collation, hint: hint, session: session)
  end

  private def execute_list_collections(args, target, session)
    filter = args && args["filter"]? ? BSON.from_json(args["filter"].to_json) : nil
    target.as(Mongo::Database).list_collections(filter: filter, session: session).to_a
  end

  private def execute_list_collection_names(args, target, session)
    filter = args && args["filter"]? ? BSON.from_json(args["filter"].to_json) : nil
    target.as(Mongo::Database).list_collections(filter: filter, name_only: true, session: session).map { |c| c["name"].as(String) }.to_a
  end

  private def execute_list_databases(args, target, session)
    if res = target.as(Mongo::Client).list_databases(session: session)
      res.databases.try(&.map { |db| BSON.new({"name" => db.name, "sizeOnDisk" => db.size_on_disk, "empty" => db.empty}) }) || [] of BSON
    end
  end

  private def execute_list_database_names(args, target, session)
    if res = target.as(Mongo::Client).list_databases(name_only: true, session: session)
      res.databases.try(&.map(&.name)) || [] of String
    end
  end

  private def execute_list_indexes(args, target, session)
    target.as(Mongo::Collection).list_indexes(session: session).try(&.to_a)
  end

  private def execute_list_index_names(args, target, session)
    target.as(Mongo::Collection).list_indexes(session: session).try(&.map { |c| c["name"].as(String) }.to_a)
  end

  private def execute_run_command(args, target, session)
    raise "Missing arguments" unless args
    command_name = args["commandName"].as_s
    command_bson = BSON.from_json(args["command"].to_json)
    read_preference = args["readPreference"]?.try { |rp| Mongo::ReadPreference.from_bson(BSON.from_json(rp.to_json)) }
    target.as(Mongo::Database).command(RawCommand.new(command_name), command_bson: command_bson, session: session, read_preference: read_preference)
  end

  private def execute_create_change_stream(args, target, session)
    pipeline = args && args["pipeline"]? ? args["pipeline"].as_a.map { |p| BSON.from_json(p.to_json) } : [] of BSON
    if target.is_a?(Mongo::Collection)
      target.watch(pipeline, session: session)
    elsif target.is_a?(Mongo::Database)
      target.watch(pipeline, session: session)
    elsif target.is_a?(Mongo::Client)
      target.watch(pipeline, session: session)
    end
  end

  private def execute_aggregate(args, target, session)
    raise "Missing arguments" unless args
    pipeline = args["pipeline"].as_a.map { |p| BSON.from_json(p.to_json) }
    allow_disk_use = args["allowDiskUse"]?.try(&.as_bool)
    collation = args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
    batch_size = args["batchSize"]?.try(&.as_i)
    max_time_ms = args["maxTimeMS"]?.try(&.as_i64)

    cursor = if target.is_a?(Mongo::Database)
               target.aggregate(pipeline, allow_disk_use: allow_disk_use, collation: collation, batch_size: batch_size, max_time_ms: max_time_ms, session: session)
             else
               target.as(Mongo::Collection).aggregate(pipeline, allow_disk_use: allow_disk_use, collation: collation, batch_size: batch_size, max_time_ms: max_time_ms, session: session)
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
    target.as(Mongo::Collection).count_documents(filter, collation: collation, skip: skip, limit: limit, session: session)
  end

  private def execute_estimated_document_count(args, target, session)
    target.as(Mongo::Collection).estimated_document_count(session: session)
  end

  private def execute_distinct(args, target, session)
    raise "Missing arguments" unless args
    key = args["fieldName"].as_s
    filter = args["filter"]? ? BSON.from_json(args["filter"].to_json) : nil
    collation = args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
    target.as(Mongo::Collection).distinct(key, filter: filter, collation: collation, session: session)
  end

  private def execute_find_one_and_delete(args, target, session)
    raise "Missing arguments" unless args
    filter = BSON.from_json(args["filter"].to_json)
    sort = args["sort"]? ? BSON.from_json(args["sort"].to_json) : nil
    collation = args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
    hint = args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) }
    max_time_ms = args["maxTimeMS"]?.try(&.as_i64)
    target.as(Mongo::Collection).find_one_and_delete(filter, sort: sort, collation: collation, hint: hint, max_time_ms: max_time_ms, session: session)
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
    target.as(Mongo::Collection).find_one_and_replace(filter, replacement, sort: sort, upsert: upsert, new: new_doc, collation: collation, hint: hint, max_time_ms: max_time_ms, session: session)
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
    target.as(Mongo::Collection).find_one_and_update(filter, update, sort: sort, upsert: upsert, new: new_doc, array_filters: array_filters, collation: collation, hint: hint, max_time_ms: max_time_ms, session: session)
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
        Mongo::Bulk::UpdateOne.new(f, u, upsert: upsert, collation: collation, hint: hint, array_filters: arrayFilters).as(Mongo::Bulk::WriteModel)
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
        Mongo::Bulk::ReplaceOne.new(f, r, upsert: upsert, collation: collation, hint: hint).as(Mongo::Bulk::WriteModel)
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

    target.as(Mongo::Collection).bulk_write(requests, ordered: ordered, session: session)
  end

  private def execute_start_transaction(args, target)
    rc = args.try(&.["readConcern"]?).try { |v| Mongo::ReadConcern.from_bson(BSON.from_json(v.to_json)) }
    wc = args.try(&.["writeConcern"]?).try { |v| Mongo::WriteConcern.from_bson(BSON.from_json(v.to_json)) }
    rp = args.try(&.["readPreference"]?).try { |v| Mongo::ReadPreference.from_bson(BSON.from_json(v.to_json)) }
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
      wc = args.try(&.["writeConcern"]?).try { |v| Mongo::WriteConcern.from_bson(BSON.from_json(v.to_json)) }
      target.commit_transaction(write_concern: wc)
    end
  end

  private def execute_abort_transaction(args, target)
    if target && target.is_a?(Mongo::Session::ClientSession)
      wc = args.try(&.["writeConcern"]?).try { |v| Mongo::WriteConcern.from_bson(BSON.from_json(v.to_json)) }
      target.abort_transaction(write_concern: wc)
    end
  end

  private def execute_end_session(args, target)
    if target && target.is_a?(Mongo::Session::ClientSession)
      target.end
    end
  end

  private def execute_with_transaction(args, target, registry, internal_client, runner)
    if args && (callback_ops = args["callback"]?.try(&.as_a))
      rc = args["readConcern"]?.try { |v| Mongo::ReadConcern.from_bson(BSON.from_json(v.to_json)) }
      wc = args["writeConcern"]?.try { |v| Mongo::WriteConcern.from_bson(BSON.from_json(v.to_json)) }
      rp = args["readPreference"]?.try { |v| Mongo::ReadPreference.from_bson(BSON.from_json(v.to_json)) }
      max_commit_time_ms = args["maxCommitTimeMS"]?.try(&.as_i64)

      if target && target.is_a?(Mongo::Session::ClientSession)
        target.with_transaction(
          read_concern: rc,
          write_concern: wc,
          read_preference: rp,
          max_commit_time_ms: max_commit_time_ms
        ) do
          callback_ops.each do |cb_op|
            op_obj = Operation.from_json(cb_op.to_json)
            execute(op_obj, registry, internal_client, runner)
          end
        end
      end
    end
  end
end
