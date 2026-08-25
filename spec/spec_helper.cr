require "spec"
require "json"
require "wait_group"
require "../src/cryomongo"

# Parallel execution for CI. The default context stays at 1 worker until resized.
# CRYSTAL_WORKERS is not applied by Crystal 1.21 unless the program resizes.
if (workers = ENV["CRYSTAL_WORKERS"]?.try(&.to_i?)) && workers > 1
  Fiber::ExecutionContext.default.resize(workers)
end

# One mongod. UTF setup turns off every failCommand and kills all sessions.
# CMAP integration and some prose tests use failCommand too. Two examples at
# once retried writes and broke expectEvents on GitHub replica set.
# UTF holds this lock for a whole JSON file (not one test), so killAllSessions
# cannot run between tests of another file. CMAP holds it per cmap-format file.
module Mongo::SpecCluster
  @@lock = Sync::Mutex.new

  def self.exclusive(&)
    @@lock.synchronize { yield }
  end
end

# Use the environment variable or a URI that matches TOPOLOGY.
ENV["MONGODB_URI"] ||= begin
  case ENV["TOPOLOGY"]?
  when "standalone", "sharded"
    "mongodb://localhost:27017"
  when "load-balanced"
    ENV["SINGLE_MONGOS_LB_URI"]? || "mongodb://127.0.0.1:8000/?loadBalanced=true"
  else
    "mongodb://127.0.0.1:27017/?replicaSet=rs0"
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

def mongodb_uri_strip_option(uri : String, name : String) : String
  return uri unless uri.includes?('?')
  base, query = uri.split('?', 2)
  kept = query.split('&').reject { |part| part.downcase.starts_with?(name.downcase + "=") }
  kept.empty? ? base : "#{base}?#{kept.join("&")}"
end

# One mongod/mongos with SDAM monitors. Load-balanced URIs have no monitors, so
# close-timing tests use this instead of MONGODB_URI.
def mongodb_uri_direct(uri : String) : String
  uri = mongodb_uri_one_host(uri)
  uri = mongodb_uri_strip_option(uri, "replicaSet")
  uri = mongodb_uri_strip_option(uri, "loadBalanced")
  uri = mongodb_uri_with(uri, "directConnection=true") unless uri.downcase.includes?("directconnection=")
  uri
end

private def drop_user_databases
  uri = ENV["MONGODB_URI"]
  client = Mongo::Client.new(mongodb_uri_with(uri, "serverSelectionTimeoutMS=2000"))
  begin
    names = [] of String
    result = client.list_databases
    result.databases.try &.each do |db|
      next if SYSTEM_DATABASES.includes?(db.name)
      names << db.name
    end
    wg = WaitGroup.new
    names.each do |name|
      wg.add(1)
      spawn do
        client[name].command(Mongo::Commands::DropDatabase) rescue nil
      ensure
        wg.done
      end
    end
    wg.wait
  rescue
    # Server may be down or not yet a replica set. Offline specs still run.
  ensure
    client.close
  end
end

# Drop leftover databases before examples. Do not drop again in after_suite:
# that extra client plus sequential drops sat in the ~18s gap after the last
# UTF file on GitHub. The next run's before_suite still cleans.
Spec.before_suite { drop_user_databases }
