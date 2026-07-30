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

  # Recursively generate a test for every JSON file — let `crystal spec`'s
  # built-in SPEC_SPLIT handle sharding, don't filter manually here.
  Dir.glob("spec/tests/unified/**/*.json").sort.each do |file|
    it "executes: #{file}" do
      runner = Mongo::Unified::Runner.new(file)
      runner.run
    end
  end
end
