require "../spec_helper"

describe "Client backpressure prose" do
  it "retries overload errors at most maxAdaptiveRetries times" do
    uri = ENV["MONGODB_URI"]
    separator = uri.includes?("?") ? "&" : "?"
    client = Mongo::Client.new("#{uri}#{separator}serverSelectionTimeoutMS=5000")
    begin
      client.command(Mongo::Commands::Ping)
    rescue e : Mongo::Error::ServerSelection
      pending! "MongoDB is not reachable (#{e.message})"
    end

    started = 0
    client.subscribe_commands do |event|
      started += 1 if event.is_a?(Mongo::Monitoring::Commands::CommandStartedEvent) && event.command_name == "find"
    end

    coll = client["prose_backpressure"]["coll"]
    begin
      client["admin"].command(
        Mongo::Commands::ConfigureFailPoint,
        fail_point: "failCommand",
        mode: "alwaysOn",
        options: {
          data: {
            failCommands: ["find"],
            errorCode:    462,
            errorLabels:  ["SystemOverloadedError", "RetryableError"],
          },
        }
      )

      error = nil
      begin
        coll.find_one({a: 1})
      rescue e : Mongo::Error
        error = e
      end

      error.should_not be_nil
      if err = error
        err.has_error_label?("SystemOverloadedError").should be_true
        err.has_error_label?("RetryableError").should be_true
      end
      started.should eq 3
    ensure
      begin
        client["admin"].command(
          Mongo::Commands::ConfigureFailPoint,
          fail_point: "failCommand",
          mode: "off"
        )
      rescue
      end
      client["prose_backpressure"].command(Mongo::Commands::DropDatabase) rescue nil
      client.close
    end
  end

  it "honors maxAdaptiveRetries=1" do
    uri = ENV["MONGODB_URI"]
    separator = uri.includes?("?") ? "&" : "?"
    client = Mongo::Client.new("#{uri}#{separator}maxAdaptiveRetries=1&serverSelectionTimeoutMS=5000")
    begin
      client.command(Mongo::Commands::Ping)
    rescue e : Mongo::Error::ServerSelection
      pending! "MongoDB is not reachable (#{e.message})"
    end

    started = 0
    client.subscribe_commands do |event|
      started += 1 if event.is_a?(Mongo::Monitoring::Commands::CommandStartedEvent) && event.command_name == "find"
    end

    coll = client["prose_backpressure"]["coll"]
    begin
      client["admin"].command(
        Mongo::Commands::ConfigureFailPoint,
        fail_point: "failCommand",
        mode: "alwaysOn",
        options: {
          data: {
            failCommands: ["find"],
            errorCode:    462,
            errorLabels:  ["SystemOverloadedError", "RetryableError"],
          },
        }
      )

      expect_raises(Mongo::Error) do
        coll.find_one({a: 1})
      end
      started.should eq 2
    ensure
      begin
        client["admin"].command(
          Mongo::Commands::ConfigureFailPoint,
          fail_point: "failCommand",
          mode: "off"
        )
      rescue
      end
      client.close
    end
  end
end
