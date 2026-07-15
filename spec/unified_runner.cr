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
    # We will add other requirements (auth, serverless, etc.) as needed
  end

  struct CollectionData
    include JSON::Serializable
    property collectionName : String
    property databaseName : String
    property documents : Array(BSON::Value)
  end

  struct EntityRequest
    include JSON::Serializable
    property id : String
    # For clients
    property uriOptions : Hash(String, BSON::Value)?
    property observeEvents : Array(String)?
    # For databases
    property client : String?
    property databaseName : String?
    # For collections
    property database : String?
    property collectionName : String?
    # For sessions
    property sessionOptions : Hash(String, BSON::Value)?
  end

  struct Operation
    include JSON::Serializable
    property name : String
    property object : String
    property arguments : Hash(String, BSON::Value)?
    property expectError : ExpectedError?
    property expectResult : BSON::Value?
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
    property commandStartedEvent : BSON::Value?
    property commandSucceededEvent : BSON::Value?
    property commandFailedEvent : BSON::Value?
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
  # The Unified Format uses strings (ids) to reference active clients,
  # databases, collections, and sessions across operations.

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
    # To be implemented in the next iteration:
    # 1. Topology checks (does our RS0 match `runOnRequirements`?)
    # 2. Populate `initialData` into the DB
    # 3. Process `createEntities` (spin up clients/dbs)
    # 4. Dispatch `operations` (CRUD, Transactions, etc.)
    # 5. Assert `outcome` and `expectEvents`
  end
end
