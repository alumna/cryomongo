require "../spec_helper"

describe "Transactions prose: write concern is not inherited from the collection" do
  it "inserts inside a transaction when the collection write concern is w: 0" do
    pending! "standalone has no transactions" if ENV["TOPOLOGY"]? == "standalone"

    uri = ENV["MONGODB_URI"]
    client = Mongo::Client.new(mongodb_uri_with(uri, "serverSelectionTimeoutMS=3000"))
    begin
      client.command(Mongo::Commands::Ping)
    rescue e : Mongo::Error::ServerSelection
      pending! "MongoDB is not reachable (#{e.message})"
    end

    begin
      db = client["prose_txn_wc"]
      db.command(Mongo::Commands::Drop, name: "coll") rescue nil
      db.command(Mongo::Commands::Create, name: "coll")
      collection = db["coll"]
      collection.write_concern = Mongo::WriteConcern.new(w: 0)

      session = client.start_session
      session.start_transaction
      collection.insert_one({n: 1}, session: session)
      session.commit_transaction
      session.end

      found = db["coll"].find_one({n: 1})
      found.should_not be_nil
    ensure
      client["prose_txn_wc"].command(Mongo::Commands::DropDatabase) rescue nil
      client.close
    end
  end
end
