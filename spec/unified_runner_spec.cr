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

  # If SPEC_SPLIT is provided (e.g. "1%4"), we only run a fraction of the tests.
  # This allows GitHub Actions to run tests concurrently across multiple jobs.
  if split = ENV["SPEC_SPLIT"]?
    part, total = split.split('%').map(&.to_i)
    files = files.each_with_index.select { |_file, i| i % total == part }.map(&.first)
  end

  # Recursively generate a test for every JSON file in our current shard
  files.each do |file|
    it "executes: #{file}" do
      runner = Mongo::Unified::Runner.new(file)
      runner.run
    end
  end
end
