require "../spec_helper"

describe "Find, getMore and killCursors commands" do
  it "uses find, getMore, and killCursors on the wire" do
    uri = ENV["MONGODB_URI"]
    separator = uri.includes?("?") ? "&" : "?"
    client = Mongo::Client.new("#{uri}#{separator}serverSelectionTimeoutMS=5000")
    begin
      client.command(Mongo::Commands::Ping)
    rescue e : Mongo::Error::ServerSelection
      pending! "MongoDB is not reachable (#{e.message})"
    end

    names = [] of String
    client.subscribe_commands do |event|
      if event.is_a?(Mongo::Monitoring::Commands::CommandStartedEvent)
        names << event.command_name
      end
    end

    db = client["prose_find_commands"]
    coll = db["coll"]
    begin
      db.command(Mongo::Commands::Drop, name: "coll") rescue nil
      5.times { |i| coll.insert_one({n: i}) }

      seen = 0
      coll.find(BSON.new, batch_size: 2) do |_doc|
        seen += 1
      end
      seen.should eq 5
      names.includes?("find").should be_true
      names.includes?("getMore").should be_true
    ensure
      db.command(Mongo::Commands::DropDatabase) rescue nil
      client.close
    end
  end
end
