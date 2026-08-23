require "bson"
require "../commands"

# Runs a map-reduce aggregation on a collection.
#
# Inline output (`out: { inline: 1 }`) is a read. Output to a collection is a write
# and must run on a primary. mapReduce is not a retryable read (Early Failures on
# Socket Disconnect).
#
# NOTE: [for more details, please check the official MongoDB documentation](https://docs.mongodb.com/manual/reference/command/mapReduce/).
module Mongo::Commands::MapReduce
  extend ReadCommand
  extend WriteCommand
  extend MayUseSecondary
  extend self

  # Returns a pair of OP_MSG body and sequences associated with the command and arguments.
  def command(database : String, collection : Collection::CollectionKey, map, reduce, output, options = nil)
    Commands.make({
      mapReduce: collection,
      map:       map,
      reduce:    reduce,
      out:       BSON.new(output),
      "$db":     database,
    }, options)
  end

  # Transforms the server result.
  def result(bson : BSON)
    bson
  end

  def write_command?(**args)
    !inline_output?(args["output"]?)
  end

  def may_use_secondary?(**args)
    inline_output?(args["output"]?)
  end

  private def inline_output?(value) : Bool
    value.is_a?(BSON) && value.has_key?("inline")
  end
end
