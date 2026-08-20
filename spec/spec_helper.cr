require "spec"
require "json"
require "../src/cryomongo"

# Use the environment variable or a URI that matches TOPOLOGY.
ENV["MONGODB_URI"] ||= begin
  case ENV["TOPOLOGY"]?
  when "standalone", "sharded"
    "mongodb://localhost:27017"
  when "load-balanced"
    ENV["SINGLE_MONGOS_LB_URI"]? || "mongodb://127.0.0.1:8000/?loadBalanced=true"
  else
    "mongodb://localhost:27017/?replicaSet=rs0"
  end
end

# Changed from :debug to :info to significantly reduce STDOUT I/O overhead during tests
Log.setup(:info)

SYSTEM_DATABASES = {"admin", "local", "config"}

# mongodb://host:port plus options must use /? not ?. The driver accepts the
# slash-less form, but Crystal's URI type would otherwise keep a trailing slash
# in the last option if a caller reconstructs the string the wrong way.
def mongodb_uri_with(uri : String, options : String) : String
  return uri if options.empty?
  if uri.includes?('?')
    "#{uri}&#{options}"
  elsif uri.ends_with?('/')
    "#{uri}?#{options}"
  else
    "#{uri}/?#{options}"
  end
end

# failCommand is per mongos. Prose tests must talk to one router so the
# fail point and the operation land on the same process.
def mongodb_uri_one_host(uri : String) : String
  parts = uri.split("://", 2)
  return uri unless parts.size == 2
  scheme, rest = parts
  cut = rest.index('/') || rest.index('?')
  host_part = cut ? rest[0, cut] : rest
  suffix = cut ? rest[cut..] : ""
  hosts = host_part.split(',').reject(&.empty?)
  return uri if hosts.size <= 1
  "#{scheme}://#{hosts[0]}#{suffix}"
end

private def drop_user_databases
  uri = ENV["MONGODB_URI"]
  client = Mongo::Client.new(mongodb_uri_with(uri, "serverSelectionTimeoutMS=2000"))
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
