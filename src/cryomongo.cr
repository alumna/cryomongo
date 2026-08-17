require "log"
require "bson"
require "./cryomongo/ext/*"
require "./cryomongo/messages/**"
require "./cryomongo/server_api"
require "./cryomongo/client"
require "./cryomongo/gridfs"

# The main Cryomongo module.
module Mongo
  VERSION = "0.13.0"

  Log = ::Log.for(self)
end
