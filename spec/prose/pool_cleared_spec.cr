require "../spec_helper"

describe "CMAP prose: PoolClearedError is retryable" do
  it "retries insertOne after a pool clear" do
    pending! "needs a replica set or sharded cluster" if ENV["TOPOLOGY"]? == "standalone"

    uri = ENV["MONGODB_URI"]
    client = Mongo::Client.new(mongodb_uri_with(uri, "maxPoolSize=1&retryWrites=true&serverSelectionTimeoutMS=8000&appname=poolClearedProse"))
    begin
      client.command(Mongo::Commands::Ping)
    rescue e : Mongo::Error::ServerSelection
      pending! "MongoDB is not reachable (#{e.message})"
    end

    started = 0
    pool_cleared = 0
    client.subscribe_commands do |event|
      started += 1 if event.is_a?(Mongo::Monitoring::Commands::CommandStartedEvent) && event.command_name == "insert"
    end
    client.subscribe_cmap do |event|
      pool_cleared += 1 if event.is_a?(Mongo::Monitoring::CMAP::PoolClearedEvent)
    end

    db = client["prose_pool_cleared"]
    coll = db["coll"]
    db.command(Mongo::Commands::Drop, name: "coll") rescue nil

    begin
      client["admin"].command(
        Mongo::Commands::ConfigureFailPoint,
        fail_point: "failCommand",
        mode: {times: 1},
        options: {
          data: {
            failCommands:    ["insert"],
            errorCode:       91,
            blockConnection: true,
            blockTimeMS:     1000,
            errorLabels:     ["RetryableWriteError"],
            appName:         "poolClearedProse",
          },
        }
      )

      errors = Channel(Exception?).new(2)
      2.times do
        spawn do
          begin
            coll.insert_one({a: 1})
            errors.send(nil)
          rescue e : Exception
            errors.send(e)
          end
        end
      end

      2.times do
        if err = errors.receive
          raise err
        end
      end

      started.should eq 3
      pool_cleared.should be >= 1
    ensure
      begin
        client["admin"].command(
          Mongo::Commands::ConfigureFailPoint,
          fail_point: "failCommand",
          mode: "off"
        )
      rescue
      end
      db.command(Mongo::Commands::DropDatabase) rescue nil
      client.close
    end
  end
end
