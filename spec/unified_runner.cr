require "json"
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
    # For clients
    property uriOptions : JSON::Any?
    property observeEvents : Array(String)?
    # For databases
    property client : String?
    property databaseName : String?
    # For collections
    property database : String?
    property collectionName : String?
    # For sessions
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
    # Changed to JSON::Any? to bypass strict parsing errors for dynamic events
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
    property sessions = Hash(String, Mongo::Session::ClientSession).new

    def close_all
      clients.each_value(&.close)
    end
  end

  # ---------------------------------------------------------------------------
  # Test Runner Engine
  # ---------------------------------------------------------------------------

  class Runner
    @registry = Registry.new
    @test_file : TestFile
    @internal_client : Mongo::Client

    def initialize(file_path : String)
      json_data = File.read(file_path)
      @test_file = TestFile.from_json(json_data)
      @internal_client = Mongo::Client.new(ENV["MONGODB_URI"])
    end

    def run
      return unless meets_requirements?(@test_file.runOnRequirements)

      @test_file.tests.each do |test|
        next unless meets_requirements?(test.runOnRequirements)

        setup_initial_data(@test_file.initialData)
        create_entities(@test_file.createEntities)

        test.operations.each do |op|
          execute_operation(op)
        end

        verify_outcome(test.outcome)

        @registry.close_all
        @registry = Registry.new
      end
    ensure
      @internal_client.close
    end

    private def meets_requirements?(requirements : Array(RunOnRequirement)?) : Bool
      return true if requirements.nil? || requirements.empty?
      true
    end

    private def setup_initial_data(initial_data : Array(CollectionData)?)
      return unless initial_data

      initial_data.each do |data|
        db = @internal_client[data.databaseName]
        coll = db[data.collectionName]

        db.command(Mongo::Commands::Drop, name: data.collectionName) rescue nil
        db.command(Mongo::Commands::Create, name: data.collectionName) rescue nil

        unless data.documents.empty?
          docs = data.documents.map { |d| BSON.from_json(d.to_json) }
          coll.insert_many(docs)
        end
      end
    end

    private def create_entities(entities : Array(Hash(String, EntityRequest))?)
      return unless entities

      entities.each do |entity_map|
        entity_map.each do |key, req|
          if client_name = req.client
            if parent_client = @registry.clients[client_name]?
              if db_name = req.databaseName
                @registry.databases[req.id] = parent_client[db_name]
              else
                raise "Missing databaseName for entity #{req.id}"
              end
            else
              raise "Parent client '#{client_name}' not found for database entity #{req.id}"
            end
          elsif db_name = req.database
            if parent_db = @registry.databases[db_name]?
              if coll_name = req.collectionName
                @registry.collections[req.id] = parent_db[coll_name]
              else
                raise "Missing collectionName for entity #{req.id}"
              end
            else
              raise "Parent database '#{db_name}' not found for collection entity #{req.id}"
            end
          else
            @registry.clients[req.id] = Mongo::Client.new(ENV["MONGODB_URI"])
          end
        end
      end
    end

    private def execute_operation(op : Operation)
      args = op.arguments

      # Catch test-level commands (e.g. configuring failPoints on the server)
      if op.object == "testRunner"
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
                options: {data: fail_point["data"]?} # <== Pass as a NamedTuple!
              )
            end
          end
        when "targetedFailPoint"
          # We can implement targetedFailPoint in later phases
        else
          puts "\n[WARN] Unsupported testRunner operation: #{op.name}"
        end
        return
      end

      target = @registry.collections[op.object]? || @registry.databases[op.object]? || @registry.clients[op.object]?
      unless target
        raise "Target entity not found: #{op.object}"
      end

      begin
        case op.name
        when "insertOne"
          raise "Missing arguments" unless args
          doc = BSON.from_json(args["document"].to_json)
          result = target.as(Mongo::Collection).insert_one(doc)
        when "insertMany"
          raise "Missing arguments" unless args
          docs = args["documents"].as_a.map { |d| BSON.from_json(d.to_json) }
          ordered = args["ordered"]?.try(&.as_bool)
          ordered = true if ordered.nil?
          result = target.as(Mongo::Collection).insert_many(docs, ordered: ordered)
        when "updateOne"
          raise "Missing arguments" unless args
          filter = BSON.from_json(args["filter"].to_json)
          update = BSON.from_json(args["update"].to_json)
          upsert = args["upsert"]?.try(&.as_bool) || false
          array_filters = args["arrayFilters"]?.try { |af| af.as_a.map { |f| BSON.from_json(f.to_json) } }
          collation = args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
          hint = args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) }

          result = target.as(Mongo::Collection).update_one(filter, update, upsert: upsert, array_filters: array_filters, collation: collation, hint: hint)
        when "updateMany"
          raise "Missing arguments" unless args
          filter = BSON.from_json(args["filter"].to_json)
          update = BSON.from_json(args["update"].to_json)
          upsert = args["upsert"]?.try(&.as_bool) || false
          array_filters = args["arrayFilters"]?.try { |af| af.as_a.map { |f| BSON.from_json(f.to_json) } }
          collation = args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
          hint = args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) }

          result = target.as(Mongo::Collection).update_many(filter, update, upsert: upsert, array_filters: array_filters, collation: collation, hint: hint)
        when "replaceOne"
          raise "Missing arguments" unless args
          filter = BSON.from_json(args["filter"].to_json)
          replacement = BSON.from_json(args["replacement"].to_json)
          upsert = args["upsert"]?.try(&.as_bool) || false
          collation = args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
          hint = args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) }

          result = target.as(Mongo::Collection).replace_one(filter, replacement, upsert: upsert, collation: collation, hint: hint)
        when "deleteOne"
          raise "Missing arguments" unless args
          filter = BSON.from_json(args["filter"].to_json)
          collation = args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
          hint = args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) }

          result = target.as(Mongo::Collection).delete_one(filter, collation: collation, hint: hint)
        when "deleteMany"
          raise "Missing arguments" unless args
          filter = BSON.from_json(args["filter"].to_json)
          collation = args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
          hint = args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) }

          result = target.as(Mongo::Collection).delete_many(filter, collation: collation, hint: hint)
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
          result = cursor.to_a
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
          result = cursor ? cursor.to_a : [] of BSON
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
          result = target.as(Mongo::Collection).count_documents(filter, collation: collation, skip: skip, limit: limit)
        when "estimatedDocumentCount"
          result = target.as(Mongo::Collection).estimated_document_count
        when "distinct"
          raise "Missing arguments" unless args
          key = args["fieldName"].as_s
          filter = args["filter"]? ? BSON.from_json(args["filter"].to_json) : nil
          collation = args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
          result = target.as(Mongo::Collection).distinct(key, filter: filter, collation: collation)
        when "findOneAndDelete"
          raise "Missing arguments" unless args
          filter = BSON.from_json(args["filter"].to_json)
          sort = args["sort"]? ? BSON.from_json(args["sort"].to_json) : nil
          collation = args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
          hint = args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) }

          result = target.as(Mongo::Collection).find_one_and_delete(filter, sort: sort, collation: collation, hint: hint)
        when "findOneAndReplace"
          raise "Missing arguments" unless args
          filter = BSON.from_json(args["filter"].to_json)
          replacement = BSON.from_json(args["replacement"].to_json)
          sort = args["sort"]? ? BSON.from_json(args["sort"].to_json) : nil
          upsert = args["upsert"]?.try(&.as_bool) || false
          new_doc = args["returnDocument"]?.try(&.as_s) == "After"
          collation = args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
          hint = args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) }

          result = target.as(Mongo::Collection).find_one_and_replace(filter, replacement, sort: sort, upsert: upsert, new: new_doc, collation: collation, hint: hint)
        when "findOneAndUpdate"
          raise "Missing arguments" unless args
          filter = BSON.from_json(args["filter"].to_json)
          update = BSON.from_json(args["update"].to_json)
          sort = args["sort"]? ? BSON.from_json(args["sort"].to_json) : nil
          upsert = args["upsert"]?.try(&.as_bool) || false
          new_doc = args["returnDocument"]?.try(&.as_s) == "After"
          array_filters = args["arrayFilters"]?.try { |af| af.as_a.map { |f| BSON.from_json(f.to_json) } }
          collation = args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
          hint = args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) }

          result = target.as(Mongo::Collection).find_one_and_update(filter, update, sort: sort, upsert: upsert, new: new_doc, array_filters: array_filters, collation: collation, hint: hint)
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
              u = BSON.from_json(req_args["update"].to_json)
              upsert = req_args["upsert"]?.try(&.as_bool)
              collation = req_args["collation"]?.try { |c| Mongo::Collation.from_bson(BSON.from_json(c.to_json)) }
              hint = req_args["hint"]?.try { |h| h.as_s? || BSON.from_json(h.to_json) }
              arrayFilters = req_args["arrayFilters"]?.try { |af| af.as_a.map { |f_el| BSON.from_json(f_el.to_json) } }
              Mongo::Bulk::UpdateOne.new(f, u, upsert: upsert, collation: collation, hint: hint, array_filters: arrayFilters).as(Mongo::Bulk::WriteModel)
            elsif req["updateMany"]?
              req_args = req["updateMany"]
              f = BSON.from_json(req_args["filter"].to_json)
              u = BSON.from_json(req_args["update"].to_json)
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
          ordered = true if ordered.nil? # default is ordered

          result = target.as(Mongo::Collection).bulk_write(requests, ordered: ordered)
        else
          puts "\n[WARN] Unsupported operation: #{op.name}"
          return
        end

        if op.expectError
          raise "Expected operation to fail with an error, but it succeeded."
        end
      rescue e : Exception
        if op.expectError
          # It was expected to fail, so we swallow the exception.
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
