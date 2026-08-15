require "spec"
require "json"
require "../src/cryomongo"

# Use the environment variable or default to the local / CI replica set
ENV["MONGODB_URI"] ||= "mongodb://localhost:27017/?replicaSet=rs0"

# Changed from :debug to :info to significantly reduce STDOUT I/O overhead during tests
Log.setup(:info)

SYSTEM_DATABASES = {"admin", "local", "config"}

private def drop_user_databases
  uri = ENV["MONGODB_URI"]
  separator = uri.includes?("?") ? "&" : "?"
  client = Mongo::Client.new("#{uri}#{separator}serverSelectionTimeoutMS=2000")
  begin
    result = client.list_databases
    result.databases.try &.each do |db|
      next if SYSTEM_DATABASES.includes?(db.name)
      client[db.name].command(Mongo::Commands::DropDatabase) rescue nil
    end
  rescue
    # Server may be down or not yet a replica set. Offline specs still run.
  ensure
    client.close
  end
end

Spec.before_suite { drop_user_databases }
Spec.after_suite { drop_user_databases }
