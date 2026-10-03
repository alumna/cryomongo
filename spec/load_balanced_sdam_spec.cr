require "./spec_helper"

describe "Load-balanced SDAM has no monitors" do
  next unless ENV["TOPOLOGY"]? == "load-balanced" || (ENV["MONGODB_URI"]?.try(&.includes?("loadBalanced=true")))

  it "does not start a heartbeat monitor after the first hello" do
    Mongo::SpecCluster.exclusive do
      uri = mongodb_uri_with(ENV["MONGODB_URI"], "serverSelectionTimeoutMS=3000")
      started = Atomic(Int32).new(0)

      client = Mongo::Client.new(uri, start_monitoring: false)
      begin
        client.subscribe_sdam do |event|
          started.add(1) if event.is_a?(Mongo::Monitoring::SDAM::ServerHeartbeatStartedEvent)
        end
        client.start_sdam_monitoring
        client.command(Mongo::Commands::Ping)
        # A wrongly added monitor would hello at once.
        sleep 200.milliseconds
        started.get.should eq 0
      rescue e : Mongo::Error::ServerSelection
        pending! "MongoDB is not reachable (#{e.message})"
      ensure
        client.close
      end
    end
  end

  it "does not start a heartbeat monitor on Client.new" do
    Mongo::SpecCluster.exclusive do
      uri = mongodb_uri_with(ENV["MONGODB_URI"], "serverSelectionTimeoutMS=3000")
      started = Atomic(Int32).new(0)

      client = Mongo::Client.new(uri)
      begin
        client.subscribe_sdam do |event|
          started.add(1) if event.is_a?(Mongo::Monitoring::SDAM::ServerHeartbeatStartedEvent)
        end
        client.command(Mongo::Commands::Ping)
        sleep 200.milliseconds
        started.get.should eq 0
      rescue e : Mongo::Error::ServerSelection
        pending! "MongoDB is not reachable (#{e.message})"
      ensure
        client.close
      end
    end
  end
end
