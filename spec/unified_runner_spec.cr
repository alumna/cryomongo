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

  it "executes insertOne.json successfully" do
    runner = Mongo::Unified::Runner.new("spec/tests/unified/insertOne.json")
    runner.run
  end
end
