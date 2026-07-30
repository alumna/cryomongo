require "./spec_helper"
require "./unified/runner"

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

  # Gather all JSON files
  files = Dir.glob("spec/tests/unified/**/*.json").sort

  # Use a custom ENV var to bypass Crystal's native SPEC_SPLIT magic.
  # This guarantees predictable, file-based sharding.
  if split = ENV["CI_SHARD"]?
    part, total = split.split('/').map(&.to_i)

    filtered_files = [] of String
    files.each_with_index do |file, index|
      filtered_files << file if index % total == part
    end
    files = filtered_files
  end

  # Recursively generate a test for every JSON file in our current shard
  files.each do |file|
    it "executes: #{file}" do
      runner = Mongo::Unified::Runner.new(file)
      runner.run
    end
  end
end
