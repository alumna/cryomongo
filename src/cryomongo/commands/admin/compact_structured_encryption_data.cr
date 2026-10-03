require "bson"
require "../commands"

# Compacts Queryable Encryption metadata collections.
# Auto-encryption fills `compactionTokens`. Use an auto-encrypting client.
#
# NOTE: [for more details, please check the official MongoDB documentation](https://www.mongodb.com/docs/manual/reference/command/compactStructuredEncryptionData/).
module Mongo::Commands::CompactStructuredEncryptionData
  extend WriteCommand
  extend self

  # Returns a pair of OP_MSG body and sequences associated with the command and arguments.
  def command(database : String, collection : Collection::CollectionKey, options = nil)
    Commands.make({
      compactStructuredEncryptionData: collection,
      "$db":                           database,
    }, options)
  end
end
