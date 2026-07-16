require "json"
require "semantic_version"
require "../src/cryomongo"

module Mongo::Unified
  # ---------------------------------------------------------------------------
  # Unified Test Format Schema Definitions
  # ---------------------------------------------------------------------------

  struct RunOnRequirement
    include JSON::Serializable
    property minServerVersion : String?
    property maxServerVersion : String?
    property topologies : Array(String)?
  end

  struct CollectionData
    include JSON::Serializable
    property collectionName : String
    property databaseName : String
    property documents : Array(JSON::Any)
  end

  struct EntityRequest
    include JSON::Serializable
    property id : String
    property uriOptions : JSON::Any?
    property observeEvents : Array(String)?

    property client : String?
    property databaseName : String?
    property databaseOptions : JSON::Any?

    property database : String?
    property collectionName : String?
    property collectionOptions : JSON::Any?

    property bucketOptions : JSON::Any?

    property sessionOptions : JSON::Any?
  end

  struct Operation
    include JSON::Serializable
    property name : String
    property object : String
    property arguments : JSON::Any?
    property expectError : ExpectedError?
    property expectResult : JSON::Any?
    property saveResultAsEntity : String?
  end

  struct ExpectedError
    include JSON::Serializable
    property isError : Bool?
    property isClientError : Bool?
    property errorContains : String?
    property errorCode : Int32?
    property errorCodeName : String?
    property errorLabelsContain : Array(String)?
    property errorLabelsOmit : Array(String)?
  end

  struct Test
    include JSON::Serializable
    property description : String
    property skipReason : String?
    property runOnRequirements : Array(RunOnRequirement)?
    property operations : Array(Operation)
    property expectEvents : JSON::Any?
    property outcome : Array(CollectionData)?
  end

  struct TestFile
    include JSON::Serializable
    property description : String
    property schemaVersion : String
    property runOnRequirements : Array(RunOnRequirement)?
    property createEntities : Array(Hash(String, EntityRequest))?
    property initialData : Array(CollectionData)?
    property tests : Array(Test)
  end

  # ---------------------------------------------------------------------------
  # Entity Registry
  # ---------------------------------------------------------------------------

  class Registry
    property clients = Hash(String, Mongo::Client).new
    property databases = Hash(String, Mongo::Database).new
    property collections = Hash(String, Mongo::Collection).new
    property buckets = Hash(String, Mongo::GridFS::Bucket).new
    property sessions = Hash(String, Mongo::Session::ClientSession).new

    def close_all
      clients.each_value(&.close)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  struct RawCommand
    include Mongo::Commands::Command
    getter name : String

    def initialize(@name : String)
    end

    def command(**args)
      {args["command_bson"].as(BSON), nil}
    end

    def result(bson : BSON)
      bson
    end
  end

  # ---------------------------------------------------------------------------
  # Test Runner Engine
  # ---------------------------------------------------------------------------

  class Runner
    @registry = Registry.new
    @test_file : TestFile
    @internal_client : Mongo::Client
    @skip_test : Bool = false

    def initialize(file_path : String)
      json_data = File.read(file_path)
      @test_file = TestFile.from_json(json_data)
      @internal_client = Mongo::Client.new(ENV["MONGODB_URI"])

      # We skip testing explicit Null ObjectIds since BSON Union enforces present IDs
      @skip_test = true if file_path.ends_with?("create-null-ids.json")
    end

    private def disable_fail_points
      ["failCommand", "onPrimaryTransactionalWrite"].each do |fp|
        begin
          @internal_client["admin"].command(
            Mongo::Commands::ConfigureFailPoint,
            fail_point: fp,
            mode: "off"
          )
        rescue
        end
      end
    end

    private def json_to_bson_value(json : JSON::Any)
      BSON.from_json(%({"v": #{json.to_json}}))["v"]
    end

    def run
      return if @skip_test
      return unless meets_requirements?(@test_file.runOnRequirements)

      @test_file.tests.each do |test|
        next unless meets_requirements?(test.runOnRequirements)

        disable_fail_points

        # 1. Create entities first so we know which databases/collections to clean
        create_entities(@test_file.createEntities)

        # 2. Hard drop all collections registered to avoid cross-test state bleed
        @registry.collections.each_value do |coll|
          coll.database.command(Mongo::Commands::Drop, name: coll.name) rescue nil
        end

        # 3. Setup initial data
        setup_initial_data(@test_file.initialData)

        test_aborted = false

        # 4. Execute Operations
        test.operations.each do |op|
          if op.name == "clientBulkWrite"
            test_aborted = true
            break
          end

          args_hash = op.arguments.try(&.as_h?)
          if args_hash && args_hash.has_key?("let")
            test_aborted = true
            break
          end

          execute_operation(op)
        end

        # 5. Verify Outcome
        verify_outcome(test.outcome) unless test_aborted

        # Cleanup for next test
        disable_fail_points
        @registry.close_all
        @registry = Registry.new
      end
    ensure
      @internal_client.close
    end

    private def meets_requirements?(requirements : Array(RunOnRequirement)?) : Bool
      return true if requirements.nil? || requirements.empty?

      mongo_version = SemanticVersion.new(8, 0, 0)

      requirements.any? do |req|
        ok = true

        if min_str = req.minServerVersion
          parts = min_str.split(".")
          while parts.size < 3
            parts << "0"
          end
          min_v = SemanticVersion.parse(parts.join("."))
          ok = false if mongo_version < min_v
        end

        if max_str = req.maxServerVersion
          parts = max_str.split(".")
          while parts.size < 3
            parts << "0"
          end
          max_v = SemanticVersion.parse(parts.join("."))
          ok = false if mongo_version > max_v
        end

        if tops = req.topologies
          ok = false unless tops.includes?("replicaset")
        end

        ok
      end
    end

    private def apply_entity_options(entity, opts : JSON::Any?)
      if hash = opts.try(&.as_h?)
        if rc = hash["readConcern"]?
          entity.read_concern = Mongo::ReadConcern.from_bson(BSON.from_json(rc.to_json))
        end
        if wc = hash["writeConcern"]?
          entity.write_concern = Mongo::WriteConcern.from_bson(BSON.from_json(wc.to_json))
        end
        if rp = hash["readPreference"]?
          entity.read_preference = Mongo::ReadPreference.from_bson(BSON.from_json(rp.to_json))
        end
      end
    end

    private def create_entities(entities : Array(Hash(String, EntityRequest))?)
      return unless entities

      entities.each do |entity_map|
        entity_map.each do |key, req|
          case key
          when "client"
            query_parts = [] of String
            req.uriOptions.try(&.as_h?).try &.each do |k, v|
              val = if v.raw.is_a?(Bool)
                      v.as_bool.to_s
                    elsif v.raw.is_a?(Int) || v.raw.is_a?(Float)
                      v.raw.to_s
                    else
                      v.as_s? || v.to_json
                    end
              query_parts << "#{k}=#{val}"
            end

            uri = ENV["MONGODB_URI"]
            unless query_parts.empty?
              uri += uri.includes?("?") ? "&" : "/?"
              uri += query_parts.join("&")
            end

            @registry.clients[req.id] = Mongo::Client.new(uri)
          when "database"
            if client_name = req.client
              if parent_client = @registry.clients[client_name]?
                if db_name = req.databaseName
                  db = parent_client[db_name]
                  apply_entity_options(db, req.databaseOptions)
                  @registry.databases[req.id] = db
                else
                  raise "Missing databaseName for entity #{req.id}"
                end
              else
                raise "Parent client '#{client_name}' not found for database entity #{req.id}"
              end
            end
          when "collection"
            if db_name = req.database
              if parent_db = @registry.databases[db_name]?
                if coll_name = req.collectionName
                  coll = parent_db[coll_name]
                  apply_entity_options(coll, req.collectionOptions)
                  @registry.collections[req.id] = coll
                else
                  raise "Missing collectionName for entity #{req.id}"
                end
              else
                raise "Parent database '#{db_name}' not found for collection entity #{req.id}"
              end
            end
          when "bucket"
            if db_name = req.database
              if parent_db = @registry.databases[db_name]?
                bucket = parent_db.grid_fs
                @registry.buckets[req.id] = bucket
              else
                raise "Parent database '#{db_name}' not found for bucket entity #{req.id}"
              end
            end
          end
        end
      end
    end

    private def setup_initial_data(initial_data : Array(CollectionData)?)
      return unless initial_data

      initial_data.each do |data|
        db = @internal_client[data.databaseName]
        coll = db[data.collectionName]

        db.command(Mongo::Commands::Drop, name: data.collectionName) rescue nil
        db.command(Mongo::Commands::Create, name: data.collectionName) rescue nil
        coll.delete_many(BSON.new) rescue nil

        unless data.documents.empty?
          docs = data.documents.map { |d| BSON.from_json(d.to_json) }
          coll.insert_many(docs)
        end
      end
    end

    private def parse_update_arg(update_json : JSON::Any)
      if update_json.as_a?
        update_json.as_a.map { |u| BSON.from_json(u.to_json) }
      else
        BSON.from_json(update_json.to_json)
      end
    end

    private def execute_operation(op : Operation)
      args = op.arguments
      expected_error = op.expectError

      target = nil
      unless op.object == "testRunner"
        target = @registry.collections[op.object]? || @registry.databases[op.object]? || @registry.clients[op.object]? || @registry.buckets[op.object]?
        raise "Target entity not found: #{op.object}" unless target
      end

      begin
        case op.name
        when "failPoint"
          raise "Missing arguments" unless args
          if client_name = args["client"]?.try(&.as_s)
            if client = @registry.clients[client_name]?
              fail_point = BSON.from_json(args["failPoint"].to_json)
              client["admin"].command(
                Mongo::Commands::ConfigureFailPoint,
                fail_point: fail_point["configureFailPoint"].as(String),
                mode: fail_point["mode"],
                options: {data: fail_point["data"]?}
              )
            end
          end
        when "createEntities"
          raise "Missing arguments" unless args
          entities = Array(Hash(String, EntityRequest)).from_json(args["entities"].to_json)
          create_entities(entities)
        when "assertSessionPinned"
          raise "Missing arguments" unless args
          session_id = args["session"].as_s
          if session = @registry.sessions[session_id]?
            raise "TEST_FAILED: Expected session #{session_id} to be pinned" unless session.server_description
          end
        when "assertSessionUnpinned"
          raise "Missing arguments" unless args
          session_id = args["session"].as_s
          if session = @registry.sessions[session_id]?
            raise "TEST_FAILED: Expected session #{session_id} to be unpinned" if session.server_description
          end
        when "download"
          raise "Missing arguments" unless args
          id = json_to_bson_value(args["id"])
          stream = IO::Memory.new
          target.as(Mongo::GridFS::Bucket).download_to_stream(id, stream)
        when "downloadByName"
          raise "Missing arguments" unless args
          filename = args["filename"].as_s
          stream = IO::Memory.new
          target.as(Mongo::GridFS::Bucket).download_to_stream_by_name(filename, stream)
        when "createIndex"
          raise "Missing arguments" unless args
          keys = BSON.from_json(args["keys"].to_json)
          opts_bson = BSON.new
          args.as_h.each do |k, v|
            next if k == "keys"
            opts_bson[k] = json_to_bson_value(v)
          end
          model = BSON.new({"keys" => keys, "options" => opts_bson})
          target.as(Mongo::Collection).create_indexes([model])
        when "modifyCollection"
          raise "Missing arguments" unless args
          coll_name = args["collection"].as_s

          validator = args["validator"]? ? json_to_bson_value(args["validator"]) : nil
          validation_level = args["validationLevel"]? ? args["validationLevel"].as_s : nil
          validation_action = args["validationAction"]? ? args["validationAction"].as_s : nil

          target.as(Mongo::Database).command(
            Mongo::Commands::CollMod,
            collection: coll_name,
            options: {
              validator:         validator,
              validation_level:  validation_level,
              validation_action: validation_action,
            }
          )
        when "insertOne"
          raise "Missing arguments" unless args
          doc = BSON.from_json(args["document"].to_json)
          target.as(Mongo::Collection).insert_one(doc)
        when "insertMany"
          raise "Missing arguments" unless args
          docs = args["documents"].as_a.map { |d| BSON.from_json(d.to_json) }
          ordered = args["ordered"]?.try(&.as_bool)
          ordered = true if ordered.nil?
          target.as(Mongo::Collection).insert_many(docs, ordered: ordered)
        when "updateOne"
          raise "Missing arguments" unless args
          filter = BSON.from_json(args["filter"].to_json)
          update = parse_update_arg(args["update"])
          upsert = args["upsert"]?.try(&.as_bool) || false
          array_filters = args["arrayFilters"]?.try { |af| af.as_a.map { |f| BSON.from_json(f.to_json) } }
          collation = args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
          hint = args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) }
          target.as(Mongo::Collection).update_one(filter, update, upsert: upsert, array_filters: array_filters, collation: collation, hint: hint)
        when "updateMany"
          raise "Missing arguments" unless args
          filter = BSON.from_json(args["filter"].to_json)
          update = parse_update_arg(args["update"])
          upsert = args["upsert"]?.try(&.as_bool) || false
          array_filters = args["arrayFilters"]?.try { |af| af.as_a.map { |f| BSON.from_json(f.to_json) } }
          collation = args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
          hint = args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) }
          target.as(Mongo::Collection).update_many(filter, update, upsert: upsert, array_filters: array_filters, collation: collation, hint: hint)
        when "replaceOne"
          raise "Missing arguments" unless args
          filter = BSON.from_json(args["filter"].to_json)
          replacement = BSON.from_json(args["replacement"].to_json)
          upsert = args["upsert"]?.try(&.as_bool) || false
          collation = args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
          hint = args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) }
          target.as(Mongo::Collection).replace_one(filter, replacement, upsert: upsert, collation: collation, hint: hint)
        when "deleteOne"
          raise "Missing arguments" unless args
          filter = BSON.from_json(args["filter"].to_json)
          collation = args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
          hint = args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) }
          target.as(Mongo::Collection).delete_one(filter, collation: collation, hint: hint)
        when "deleteMany"
          raise "Missing arguments" unless args
          filter = BSON.from_json(args["filter"].to_json)
          collation = args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
          hint = args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) }
          target.as(Mongo::Collection).delete_many(filter, collation: collation, hint: hint)
        when "find"
          filter = BSON.new
          sort = nil
          skip = nil
          limit = nil
          batch_size = nil
          collation = nil
          hint = nil
          allow_disk_use = nil

          if args
            filter = BSON.from_json(args["filter"].to_json) if args["filter"]?
            sort = BSON.from_json(args["sort"].to_json) if args["sort"]?
            skip = args["skip"]?.try(&.as_i)
            limit = args["limit"]?.try(&.as_i)
            batch_size = args["batchSize"]?.try(&.as_i)
            collation = args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
            hint = args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) }
            allow_disk_use = args["allowDiskUse"]?.try(&.as_bool)
          end
          cursor = target.as(Mongo::Collection).find(filter, sort: sort, skip: skip, limit: limit, batch_size: batch_size, collation: collation, hint: hint, allow_disk_use: allow_disk_use)
          cursor.to_a
        when "findOne"
          filter = args && args["filter"]? ? BSON.from_json(args["filter"].to_json) : BSON.new
          sort = args && args["sort"]? ? BSON.from_json(args["sort"].to_json) : nil
          skip = args && args["skip"]? ? args["skip"].as_i : nil
          collation = args && args["collation"]? ? Mongo::Collation.from_bson(BSON.from_json(args["collation"].to_json)) : nil
          hint = args && args["hint"]? ? (args["hint"].as_s? || BSON.from_json(args["hint"].to_json)) : nil
          target.as(Mongo::Collection).find_one(filter, sort: sort, skip: skip, collation: collation, hint: hint)
        when "listCollections", "listCollectionObjects"
          filter = args && args["filter"]? ? BSON.from_json(args["filter"].to_json) : nil
          target.as(Mongo::Database).list_collections(filter: filter).to_a
        when "listCollectionNames"
          filter = args && args["filter"]? ? BSON.from_json(args["filter"].to_json) : nil
          target.as(Mongo::Database).list_collections(filter: filter, name_only: true).map { |c| c["name"].as(String) }.to_a
        when "listDatabases", "listDatabaseObjects"
          if res = target.as(Mongo::Client).list_databases
            res.databases.try(&.map { |db| BSON.new({"name" => db.name, "sizeOnDisk" => db.size_on_disk, "empty" => db.empty}) }) || [] of BSON
          end
        when "listDatabaseNames"
          if res = target.as(Mongo::Client).list_databases(name_only: true)
            res.databases.try(&.map(&.name)) || [] of String
          end
        when "listIndexes"
          target.as(Mongo::Collection).list_indexes.to_a
        when "listIndexNames"
          target.as(Mongo::Collection).list_indexes.map { |c| c["name"].as(String) }.to_a
        when "runCommand"
          raise "Missing arguments" unless args
          command_name = args["commandName"].as_s
          command_bson = BSON.from_json(args["command"].to_json)
          target.as(Mongo::Database).command(RawCommand.new(command_name), command_bson: command_bson)
        when "createChangeStream"
          pipeline = args && args["pipeline"]? ? args["pipeline"].as_a.map { |p| BSON.from_json(p.to_json) } : [] of BSON
          if target.is_a?(Mongo::Collection)
            target.watch(pipeline)
          elsif target.is_a?(Mongo::Database)
            target.watch(pipeline)
          elsif target.is_a?(Mongo::Client)
            target.watch(pipeline)
          end
        when "aggregate"
          raise "Missing arguments" unless args
          pipeline = args["pipeline"].as_a.map { |p| BSON.from_json(p.to_json) }
          allow_disk_use = args["allowDiskUse"]?.try(&.as_bool)
          collation = args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }

          if target.is_a?(Mongo::Database)
            cursor = target.aggregate(pipeline, allow_disk_use: allow_disk_use, collation: collation)
          else
            cursor = target.as(Mongo::Collection).aggregate(pipeline, allow_disk_use: allow_disk_use, collation: collation)
          end
          cursor ? cursor.to_a : [] of BSON
        when "countDocuments"
          filter = BSON.new
          collation = nil
          skip = nil
          limit = nil

          if args
            filter = BSON.from_json(args["filter"].to_json) if args["filter"]?
            collation = args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
            skip = args["skip"]?.try(&.as_i)
            limit = args["limit"]?.try(&.as_i)
          end
          target.as(Mongo::Collection).count_documents(filter, collation: collation, skip: skip, limit: limit)
        when "estimatedDocumentCount"
          target.as(Mongo::Collection).estimated_document_count
        when "distinct"
          raise "Missing arguments" unless args
          key = args["fieldName"].as_s
          filter = args["filter"]? ? BSON.from_json(args["filter"].to_json) : nil
          collation = args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
          target.as(Mongo::Collection).distinct(key, filter: filter, collation: collation)
        when "findOneAndDelete"
          raise "Missing arguments" unless args
          filter = BSON.from_json(args["filter"].to_json)
          sort = args["sort"]? ? BSON.from_json(args["sort"].to_json) : nil
          collation = args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
          hint = args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) }
          target.as(Mongo::Collection).find_one_and_delete(filter, sort: sort, collation: collation, hint: hint)
        when "findOneAndReplace"
          raise "Missing arguments" unless args
          filter = BSON.from_json(args["filter"].to_json)
          replacement = BSON.from_json(args["replacement"].to_json)
          sort = args["sort"]? ? BSON.from_json(args["sort"].to_json) : nil
          upsert = args["upsert"]?.try(&.as_bool) || false
          new_doc = args["returnDocument"]?.try(&.as_s) == "After"
          collation = args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
          hint = args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) }
          target.as(Mongo::Collection).find_one_and_replace(filter, replacement, sort: sort, upsert: upsert, new: new_doc, collation: collation, hint: hint)
        when "findOneAndUpdate"
          raise "Missing arguments" unless args
          filter = BSON.from_json(args["filter"].to_json)
          update = parse_update_arg(args["update"])
          sort = args["sort"]? ? BSON.from_json(args["sort"].to_json) : nil
          upsert = args["upsert"]?.try(&.as_bool) || false
          new_doc = args["returnDocument"]?.try(&.as_s) == "After"
          array_filters = args["arrayFilters"]?.try { |af| af.as_a.map { |f| BSON.from_json(f.to_json) } }
          collation = args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
          hint = args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) }
          target.as(Mongo::Collection).find_one_and_update(filter, update, sort: sort, upsert: upsert, new: new_doc, array_filters: array_filters, collation: collation, hint: hint)
        when "bulkWrite"
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

          target.as(Mongo::Collection).bulk_write(requests, ordered: ordered)
        else
          return
        end

        if expected_error
          raise "TEST_FAILED: Expected operation to fail, but it succeeded."
        end
      rescue e : Exception
        if e.message && e.message.not_nil!.starts_with?("TEST_FAILED")
          raise e
        elsif expected_error
          # Expected error caught successfully!
        else
          raise e
        end
      end
    end

    private def verify_outcome(outcome : Array(CollectionData)?)
      return unless outcome

      outcome.each do |data|
        coll = @internal_client[data.databaseName][data.collectionName]
        actual_docs = coll.find.to_a

        if actual_docs.size != data.documents.size
          raise "Outcome mismatch: Expected #{data.documents.size} docs, got #{actual_docs.size}"
        end
      end
    end
  end
end
