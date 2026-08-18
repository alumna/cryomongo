require "bson"
require "../commands"

# Performs aggregation operation using the aggregation pipeline.
# The pipeline allows users to process data from a collection or other source with a sequence of stage-based manipulations.
#
# NOTE: [for more details, please check the official MongoDB documentation](https://docs.mongodb.com/manual/reference/command/aggregate/).
module Mongo::Commands::Aggregate
  extend ReadCommand
  extend WriteCommand
  extend MayUseSecondary
  extend Retryable
  extend self

  # Returns a pair of OP_MSG body and sequences associated with the command and arguments.
  def command(database : String, collection : Collection::CollectionKey, pipeline : Array, options = nil)
    need_cursor = true
    options.try &.each { |key, value|
      need_cursor = false if (key.to_s == "explain" || key.to_s == "cursor") && !value.nil?
    }
    if need_cursor
      Commands.make({
        "aggregate": collection,
        "pipeline":  pipeline.map { |elt| BSON.new(elt) },
        "$db":       database,
        "cursor":    BSON.new,
      }, options)
    else
      Commands.make({
        "aggregate": collection,
        "pipeline":  pipeline.map { |elt| BSON.new(elt) },
        "$db":       database,
      }, options)
    end
  end

  # Transforms the server result.
  def result(bson : BSON)
    raise Mongo::Error.new "Explain is not supported" unless bson["cursor"]?
    Common::QueryResult.from_bson bson
  end

  def write_command?(**args)
    args["pipeline"]?.try { |pipeline|
      pipeline.as(Array).map { |elt| BSON.new(elt) }.any? { |stage|
        stage["$out"]? || stage["$merge"]?
      }
    }
  end

  def may_use_secondary?(**args)
    # MongoDB 5.0+ honors the user's read preference for $out / $merge.
    # This driver targets 8.0, so write aggregations may use secondaries.
    true
  end

  def retryable?(**args)
    !write_command?(**args) unless self.prevent_retry(args)
  end
end
