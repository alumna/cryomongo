require "spec"
require "json"
require "../src/cryomongo"

# Use the environment variable or default to the Docker replica set we created in CI
ENV["MONGODB_URI"] ||= "mongodb://localhost:27017/?replicaSet=rs0"

Log.setup(:debug)

# We will require our new Unified Runner here once we build it
# require "./unified_runner"
