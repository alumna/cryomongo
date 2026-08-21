require "log"
require "bson"
require "./cryomongo/compression"
require "./cryomongo/ext/*"
require "./cryomongo/messages/**"
require "./cryomongo/server_api"
require "./cryomongo/deadline"
require "./cryomongo/timeout_mode"
require "./cryomongo/cursor_type"
require "./cryomongo/client"
require "./cryomongo/gridfs"

# The main Cryomongo module.
module Mongo
  VERSION = "0.16.0"

  Log = ::Log.for(self)
end
