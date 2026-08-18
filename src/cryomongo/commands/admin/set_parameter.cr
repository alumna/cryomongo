require "bson"
require "../commands"

# *setParameter* is an administrative command for modifying options normally set on the command line.
#
# NOTE: [for more details, please check the official MongoDB documentation](https://docs.mongodb.com/manual/reference/command/setParameter/).
module Mongo::Commands::SetParameter
  extend Command
  extend self

  # Returns a pair of OP_MSG body and sequences associated with the command and arguments.
  def command(parameter : String, value)
    bson = BSON.build do |builder|
      builder["setParameter"] = 1
      builder["$db"] = "admin"
      Tools.write_bson_field(builder, parameter, value)
    end
    {bson, nil}
  end
end
