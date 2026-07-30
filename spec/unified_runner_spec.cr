require "./spec_helper"
require "./unified/runner"
require "./sharding"

describe "Unified Test Runner" do
  it "bootstraps the environment successfully" do
    client = Mongo::Client.new(ENV["MONGODB_URI"])
    response = client.command(Mongo::Commands::Ping)

    if response
      response.ok.should eq(1.0)
    else
      fail "Expected a response, but got nil"
    end

    client.close
  end

  # Gather all JSON files and sort them deterministically
  files = Dir.glob("spec/tests/unified/**/*.json").sort

  # Dynamically filter the files using our cost-aware bin-packing algorithm
  files = Mongo::SpecSharding.filter(files)

  # Recursively generate a test for every JSON file in our current shard
  files.each do |file|
    it "executes: #{file}" do
      runner = Mongo::Unified::Runner.new(file)
      runner.run
    end
  end
end
