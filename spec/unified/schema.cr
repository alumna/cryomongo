require "json"

module Mongo::Unified
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
end
