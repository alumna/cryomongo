require "./tools"

module Mongo
  # Specifies the version of the MongoDB API to use for operations.
  #
  # See: https://www.mongodb.com/docs/manual/reference/server-api/
  struct ServerApi
    include Tools::Initializer

    getter version : String
    getter strict : Bool? = nil
    getter deprecation_errors : Bool? = nil
  end
end
