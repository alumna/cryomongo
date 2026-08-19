require "./spec_helper"
require "./support/selection_fixture"
require "./sharding"

describe "Server selection spec tests" do
  files = Dir.glob("spec/tests/legacy/server-selection/logic/**/*.json").sort
  files = Mongo::SpecSharding.filter(files)

  files.each do |file|
    it "selects servers in #{file}" do
      json = JSON.parse(File.read(file))
      topology_type = Mongo::SpecSupport.topology_type(json["topology_description"]["type"].as_s)
      servers = Mongo::SpecSupport.servers_from_json(json["topology_description"]["servers"])
      read_pref = Mongo::SpecSupport.read_preference_from_json(json["read_preference"]?)
      write = json["operation"]?.try(&.as_s?) == "write"
      heartbeat = Mongo::SpecSupport.heartbeat_frequency(json)

      suitable = Mongo::SDAM::Selector.suitable_servers(
        topology_type,
        servers,
        read_pref,
        write: write,
        heartbeat_frequency: heartbeat
      )
      window = Mongo::SDAM::Selector.in_latency_window(suitable)

      expected_suitable = json["suitable_servers"].as_a.map { |s| s["address"].as_s }.sort
      expected_window = json["in_latency_window"].as_a.map { |s| s["address"].as_s }.sort
      suitable.map(&.address).sort.should eq expected_suitable
      window.map(&.address).sort.should eq expected_window
    end
  end
end
