require "../spec_helper"

describe "Wire compression prose" do
  it "pings with compressors=zlib" do
    base = ENV["MONGODB_URI"]
    uri = mongodb_uri_with(base, "compressors=zlib&serverSelectionTimeoutMS=3000")
    client = Mongo::Client.new(uri)
    begin
      response = client.command(Mongo::Commands::Ping)
      response.try(&.ok).should eq 1.0
    rescue e : Mongo::Error::ServerSelection
      pending! "MongoDB is not reachable (#{e.message})"
    ensure
      client.close
    end
  end

  it "inserts and finds a document with compressors=zlib" do
    base = ENV["MONGODB_URI"]
    uri = mongodb_uri_with(base, "compressors=zlib&serverSelectionTimeoutMS=3000")
    client = Mongo::Client.new(uri)
    begin
      db = client["prose_compression"]
      coll = db["docs"]
      db.command(Mongo::Commands::Drop, name: "docs") rescue nil
      payload = "x" * 4096
      coll.insert_one({n: 1, blob: payload})
      doc = coll.find_one({n: 1})
      doc.try(&.["blob"]).should eq payload
    rescue e : Mongo::Error::ServerSelection
      pending! "MongoDB is not reachable (#{e.message})"
    ensure
      begin
        client["prose_compression"].command(Mongo::Commands::DropDatabase)
      rescue
      end
      client.close
    end
  end
end
