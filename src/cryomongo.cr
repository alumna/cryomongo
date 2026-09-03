require "log"
require "bson"

module Mongo
  VERSION = "0.17.5"

  Log = ::Log.for(self)
end

require "./cryomongo/logging"
require "./cryomongo/compression"
require "./cryomongo/ext/*"
require "./cryomongo/messages/**"
require "./cryomongo/server_api"
require "./cryomongo/deadline"
require "./cryomongo/timeout_mode"
require "./cryomongo/cursor_type"
require "./cryomongo/client"
require "./cryomongo/gridfs"
require "./cryomongo/client_encryption"
