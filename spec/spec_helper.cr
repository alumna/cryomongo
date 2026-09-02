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
# Live prose that talks to mongod (ping, insert, RTT sleep) must use this lock
# too: CRYSTAL_WORKERS=2 otherwise overlaps UTF failCommand and extra insert
# retries (Wave 11 replica-set GitHub errors).
# Timing logs after v0.17.1 showed 0 overlapping UTF files; leftover failCommand
# on a paused / Unknown member still retried the next insert.
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

# Drop user:pass so a leftover saslContinue failCommand cannot block
# configureFailPoint. Spec topologies do not use --auth; SASL only runs when
# the URI has userinfo.
def mongodb_uri_strip_userinfo(uri : String) : String
  parts = uri.split("://", 2)
  return uri unless parts.size == 2
  scheme, rest = parts
  if at = rest.rindex('@')
    "#{scheme}://#{rest[at + 1..]}"
  else
    uri
  end
end

# Direct mongod used to turn failCommand off. No userinfo, unique appName,
# retryWrites=false, long poll heartbeat. First handshake is before UTF sets a
# failPoint; later calls reuse that socket. Do not use start_monitoring: false:
# Single + Unknown never marks the pool ready, so mode=off waits out SST.
def mongodb_uri_failpoint_off(uri : String, address : String) : String
  built = mongodb_uri_direct_address(uri, address)
  built = mongodb_uri_strip_userinfo(built)
  built = mongodb_uri_strip_option(built, "retryWrites")
  built = mongodb_uri_strip_option(built, "appname")
  built = mongodb_uri_strip_option(built, "heartbeatFrequencyMS")
  built = mongodb_uri_strip_option(built, "serverMonitoringMode")
  mongodb_uri_with(built, "serverSelectionTimeoutMS=3000&retryWrites=false&appName=cryomongo-failpoint-off&heartbeatFrequencyMS=1000000&serverMonitoringMode=poll")
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

# First host in the URI (GitHub replica set is often a secondary on 27017).
def mongodb_seed_address(uri : String) : String?
  rest = uri.split("://", 2)[1]?
  return nil unless rest
  hostpart = rest.includes?('@') ? rest.split('@', 2)[1] : rest
  cut = hostpart.index('/') || hostpart.index('?')
  raw = cut ? hostpart[0, cut] : hostpart
  return nil if raw.empty?
  raw.includes?(':') ? raw.downcase : "#{raw.downcase}:27017"
end

# One mongod at `address`, same credentials as `uri`. FailPoint-off strips userinfo after this.
def mongodb_uri_direct_address(uri : String, address : String) : String
  parts = uri.split("://", 2)
  return uri unless parts.size == 2
  scheme, rest = parts
  userinfo = ""
  hostrest = rest
  if at = rest.rindex('@')
    userinfo = rest[0, at + 1]
    hostrest = rest[at + 1..]
  end
  cut = hostrest.index('/') || hostrest.index('?')
  suffix = cut ? hostrest[cut..] : ""
  built = "#{scheme}://#{userinfo}#{address}#{suffix}"
  built = mongodb_uri_strip_option(built, "replicaSet")
  built = mongodb_uri_strip_option(built, "loadBalanced")
  built = mongodb_uri_strip_option(built, "directConnection")
  mongodb_uri_with(built, "directConnection=true")
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
