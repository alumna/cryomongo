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
    # Replaced BSON with JSON::Any to bypass protected BSON constructors
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
    property arguments : JSON::Any? # Replaced BSON with JSON::Any
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

  struct EventExpectation
    include JSON::Serializable
    property commandStartedEvent : JSON::Any?
    property commandSucceededEvent : JSON::Any?
    property commandFailedEvent : JSON::Any?
  end

  struct Test
    include JSON::Serializable
    property description : String
    property skipReason : String?
    property runOnRequirements : Array(RunOnRequirement)?
    property operations : Array(Operation)
    property expectEvents : Array(Hash(String, Array(EventExpectation)))?
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

        # Call Drop and Create on the Database object, passing 'name'
        db.command(Mongo::Commands::Drop, name: data.collectionName) rescue nil
        db.command(Mongo::Commands::Create, name: data.collectionName) rescue nil

        unless data.documents.empty?
          # Convert JSON::Any to BSON
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
      target = @registry.collections[op.object]? || @registry.databases[op.object]? || @registry.clients[op.object]?
      unless target
        raise "Target entity not found: #{op.object}"
      end

      case op.name
      when "insertOne"
        args = op.arguments
        unless args
          raise "Missing arguments for insertOne operation"
        end

        doc_json = args["document"]?
        unless doc_json
          raise "insertOne argument 'document' is missing"
        end

        # Safely convert the JSON tree to BSON Extended JSON format
        doc = BSON.from_json(doc_json.to_json)

        if target.is_a?(Mongo::Collection)
          result = target.insert_one(doc)

          if expected = op.expectResult
            if result.nil?
              raise "Expected result but got nil"
            end
          end
        else
          raise "Target for insertOne must be a Collection, but got #{target.class}"
        end
      else
        raise "Unsupported operation: #{op.name}"
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
