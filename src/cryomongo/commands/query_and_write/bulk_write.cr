require "bson"
require "../commands"

# The *bulkWrite* command (MongoDB 8.0) runs insert, update, and delete
# operations across mixed namespaces. The command body is on `admin`.
# `ops` and `nsInfo` go as OP_MSG document sequences.
#
# NOTE: [for more details, please check the official MongoDB documentation](https://www.mongodb.com/docs/manual/reference/command/bulkWrite/).
module Mongo::Commands::BulkWrite
  extend WriteCommand
  extend Retryable
  extend self

  # Returns a pair of OP_MSG body and sequences associated with the command and arguments.
  def command(ops : Array(BSON), ns_info : Array(BSON), options)
    Commands.make({
      bulkWrite: 1,
      "$db":     "admin",
    }, sequences: {
      ops:    ops,
      nsInfo: ns_info,
    }, options: options)
  end

  # A batch is retryable only when every op in that batch is retryable.
  # `multi: true` (updateMany / deleteMany) makes the batch not retryable.
  def retryable?(**args)
    return false if prevent_retry(args)
    ops = args["ops"]?
    return true unless ops
    ops.each do |op|
      next unless op.is_a?(BSON)
      return false if op["multi"]? == true
    end
    true
  end

  Common.result(Result) {
    property n_errors : Int32?
    property n_inserted : Int32?
    property n_matched : Int32?
    property n_modified : Int32?
    property n_upserted : Int32?
    property n_deleted : Int32?
    property write_concern_error : Common::WriteConcernError?
    property cursor : Common::Cursor?
  }

  # Transforms the server result.
  def result(bson : BSON)
    Result.from_bson bson
  end
end
