require "../spec_helper"

describe "SDAM prose: RTT is updated by the monitor" do
  it "keeps a non-zero RTT after heartbeats" do
    uri = mongodb_uri_one_host(ENV["MONGODB_URI"])
    client = Mongo::Client.new(mongodb_uri_with(uri, "heartbeatFrequencyMS=500&appname=streamingRttTest&serverSelectionTimeoutMS=5000"))
    begin
      client.command(Mongo::Commands::Ping)
    rescue e : Mongo::Error::ServerSelection
      pending! "MongoDB is not reachable (#{e.message})"
    end

    begin
      sleep 2.seconds
      servers = client.topology.servers.select { |s| !s.type.unknown? }
      servers.should_not be_empty
      servers.each do |server|
        rtt = client.server_round_trip_time(server.address)
        rtt.should_not be_nil
        if rtt
          rtt.should be > Time::Span.zero
        end
      end
    ensure
      client.close
    end
  end
end
