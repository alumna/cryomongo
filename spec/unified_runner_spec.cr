require "./spec_helper"
require "./unified/runner"
require "./unified/filter"
require "./unified/timing"
require "./sharding"

describe "Unified Test Runner" do
  Spec.before_suite { Mongo::Unified::Timing.start_suite }
  Spec.after_suite do
    Mongo::Unified::Timing.finish_suite
    Mongo::Unified::Runner.close_shared_client
  end

  it "maps CI topology names to official UTF topology names" do
    Mongo::Unified::Runner.utf_topology_name("standalone").should eq "single"
    Mongo::Unified::Runner.utf_topology_name("replicaset").should eq "replicaset"
    Mongo::Unified::Runner.utf_topology_name("sharded").should eq "sharded"
    Mongo::Unified::Runner.utf_topology_name("single").should eq "single"
    Mongo::Unified::Runner.utf_topology_name("load-balanced").should eq "load-balanced"
    Mongo::Unified::Runner.utf_topology_name("load_balanced").should eq "load-balanced"
  end

  it "omits UTF files whose topologies do not include the current topology" do
    lb = "spec/tests/unified/load-balancers/cursors.json"
    rs = "spec/tests/unified/retryable-writes/insertOne.json"
    Mongo::Unified::TopologyFilter.keep?(lb, "sharded").should be_false
    Mongo::Unified::TopologyFilter.keep?(lb, "load-balanced").should be_true
    Mongo::Unified::TopologyFilter.keep?(rs, "sharded").should be_false
    Mongo::Unified::TopologyFilter.keep?(rs, "replicaset").should be_true
  end

  it "bootstraps the environment successfully" do
    Mongo::SpecCluster.exclusive do
      uri = ENV["MONGODB_URI"]
      client = Mongo::Client.new(mongodb_uri_with(uri, "serverSelectionTimeoutMS=3000"))
      begin
        response = client.command(Mongo::Commands::Ping)
        if response
          response.ok.should eq(1.0)
        else
          fail "Expected a response, but got nil"
        end
      rescue e : Mongo::Error::ServerSelection
        pending! "MongoDB is not reachable as a replica set (#{e.message}). Run: sudo scripts/mongo-topology.sh replicaset"
      ensure
        client.close
      end
    end
  end

  it "closes a client without waiting a full heartbeat" do
    Mongo::SpecCluster.exclusive do
      uri = mongodb_uri_direct(ENV["MONGODB_URI"])
      client = Mongo::Client.new(mongodb_uri_with(uri, "serverSelectionTimeoutMS=3000"))
      begin
        client.command(Mongo::Commands::Ping)
      rescue e : Mongo::Error::ServerSelection
        pending! "MongoDB is not reachable as a replica set (#{e.message}). Run: sudo scripts/mongo-topology.sh replicaset"
      end
      # First hello is a handshake. Wait so awaitable hello is in flight (the
      # GitHub ~18s hang was a long-lived client, not close-right-after-ping).
      sleep 500.milliseconds
      started = Time.instant
      client.close
      (Time.instant - started).should be < 3.seconds
    end
  end

  # Gather all JSON files and sort them deterministically
  files = Dir.glob("spec/tests/unified/**/*.json").sort

  # Dynamically filter the files using our cost-aware bin-packing algorithm
  files = Mongo::SpecSharding.filter(files)

  # Recursively generate a test for every JSON file in our current shard.
  # Wrong-topology files are omitted (not Crystal pending). Newer-server files stay pending.
  utf_topology = ENV["TOPOLOGY"]?.try { |value| Mongo::Unified::Runner.utf_topology_name(value) }
  files.each do |file|
    next if utf_topology && !Mongo::Unified::TopologyFilter.keep?(file, utf_topology)
    it "executes: #{file}" do
      runner = Mongo::Unified::Runner.new(file)
      runner.run
    rescue e : Mongo::Unified::Skip
      pending! e.message || "skipped"
    rescue e : Mongo::Error::ServerSelection
      pending! "MongoDB is not reachable as a replica set (#{e.message}). Run: sudo scripts/mongo-topology.sh replicaset"
    end
  end
end
