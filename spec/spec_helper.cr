require "spec"
require "json"
require "../src/cryomongo"

# Use the environment variable or default to the Docker replica set we created in CI
ENV["MONGODB_URI"] ||= "mongodb://localhost:27017/?replicaSet=rs0"

# Changed from :debug to :info to significantly reduce STDOUT I/O overhead during tests
Log.setup(:info)
