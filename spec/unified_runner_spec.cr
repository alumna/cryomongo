require "./spec_helper"
require "./unified_runner"

describe "Unified Test Runner" do
  it "bootstraps the environment successfully" do
    client = Mongo::Client.new(ENV["MONGODB_URI"])

    response = client.command(Mongo::Commands::Ping)
    response.should_not be_nil
    response.not_nil!.ok.should eq(1.0) # <== Access the property directly

    client.close
  end
end
