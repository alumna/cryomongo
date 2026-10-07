require "log"
require "bson"

# macOS is not a supported target. Darwin-only branches stay in the
# source and are not maintained. Linux is the suite.
{% if flag?(:darwin) %}
  {% raise "cryomongo supports Linux only. macOS is not a supported target." %}
{% end %}

module Mongo
  VERSION = "1.0.0"

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
