require "./spec_helper"
require "./support/selection_fixture"
require "./sharding"

describe "Max staleness spec tests" do
  files = Dir.glob("spec/tests/legacy/max-staleness/**/*.json").sort
  files = Mongo::SpecSharding.filter(files)

  files.each do |file|
    it "applies max staleness in #{file}" do
      json = JSON.parse(File.read(file))
      topology_type = Mongo::SpecSupport.topology_type(json["topology_description"]["type"].as_s)
      servers = Mongo::SpecSupport.servers_from_json(json["topology_description"]["servers"])
      read_pref = Mongo::SpecSupport.read_preference_from_json(json["read_preference"]?)
      heartbeat = Mongo::SpecSupport.heartbeat_frequency(json)

      if json["error"]?.try(&.as_bool)
        expect_raises(Mongo::Error::ServerSelection) do
          Mongo::SDAM::Selector.suitable_servers(
            topology_type,
            servers,
            read_pref,
            heartbeat_frequency: heartbeat
          )
        end
      else
        suitable = Mongo::SDAM::Selector.suitable_servers(
          topology_type,
          servers,
          read_pref,
          heartbeat_frequency: heartbeat
        )
        window = Mongo::SDAM::Selector.in_latency_window(suitable)
        expected_window = json["in_latency_window"].as_a.map { |s| s["address"].as_s }.sort
        window.map(&.address).sort.should eq expected_window
      end
    end
  end
end
