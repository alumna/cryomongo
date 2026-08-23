require "bson"
require "../commands"

# The *insert* command inserts one or more documents and returns a document containing the status of all inserts.
#
# NOTE: [for more details, please check the official MongoDB documentation](https://docs.mongodb.com/manual/reference/command/insert/).
module Mongo::Commands::Insert
  extend WriteCommand
  extend Retryable
  extend self

  # Generate `_id` on each document and put it first (CRUD prose: generated identifiers are the first field).
  # If `_id` is already present, leave the document as-is. BSON.new is a no-op for BSON.
  def with_ids(documents : Array) : Array(BSON)
    documents.map { |elt|
      src = BSON.new(elt)
      if src.has_key?("_id")
        src
      else
        id = BSON::ObjectId.new
        BSON.build do |builder|
          builder["_id"] = id
          src.each { |key, value, code|
            if value.is_a?(BSON) && code.array?
              builder.append_array(key, value)
            else
              builder[key] = value
            end
          }
        end
      end
    }
  end

  # Returns a pair of OP_MSG body and sequences associated with the command and arguments.
  def command(database : String, collection : Collection::CollectionKey, documents : Array, options)
    Commands.make({
      insert: collection,
      "$db":  database,
    }, sequences: {
      documents: with_ids(documents),
    }, options: options)
  end

  def retryable?(**args)
    # insertOne and insertMany are both retryable as a single insert command
    # (same txnNumber). Client-generated _id makes the retry safe.
    true unless prevent_retry(args)
  end

  # Transforms the server result.
  def result(bson : BSON)
    Common::InsertResult.from_bson bson
  end
end
