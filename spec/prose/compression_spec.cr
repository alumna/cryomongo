require "../spec_helper"

private def with_compressor(name : String, &)
  base = ENV["MONGODB_URI"]
  uri = mongodb_uri_with(base, "compressors=#{name}&serverSelectionTimeoutMS=3000")
  client = Mongo::Client.new(uri)
  begin
    yield client
  rescue e : Mongo::Error::ServerSelection
    pending! "MongoDB is not reachable (#{e.message})"
  ensure
    client.close
  end
end

describe "Wire compression prose" do
  %w(zlib snappy zstd).each do |name|
    it "pings with compressors=#{name}" do
      with_compressor(name) do |client|
        response = client.command(Mongo::Commands::Ping)
        response.try(&.ok).should eq 1.0
      end
    end

    it "inserts and finds a document with compressors=#{name}" do
      with_compressor(name) do |client|
        db = client["prose_compression_#{name}"]
        coll = db["docs"]
        db.command(Mongo::Commands::Drop, name: "docs") rescue nil
        payload = "x" * 4096
        coll.insert_one({n: 1, blob: payload})
        doc = coll.find_one({n: 1})
        doc.try(&.["blob"]).should eq payload
        db.command(Mongo::Commands::DropDatabase) rescue nil
      end
    end
  end
end
