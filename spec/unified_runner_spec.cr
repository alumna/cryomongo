require "./spec_helper"
require "./unified_runner"

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

  # Dynamically generate a test for every JSON file in the directory
  Dir.glob("spec/tests/unified/*.json").each do |file|
    it "executes #{File.basename(file)} successfully" do
      runner = Mongo::Unified::Runner.new(file)
      runner.run
    end
  end
end
