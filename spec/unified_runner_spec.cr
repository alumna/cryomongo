require "./spec_helper"
require "./unified_runner"

describe "Unified Test Runner" do
  it "bootstraps the environment successfully" do
    # This just ensures our test suite compiles and runs the docker container
    client = Mongo::Client.new(ENV["MONGODB_URI"])

    # Send a ping to our Mongo 8.0 Docker container to verify connection
    response = client.command(Mongo::Commands::Ping)
    response.should_not be_nil
    response.try &.["ok"].should eq(1.0)

    client.close
  end
end
