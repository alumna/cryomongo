require "../spec_helper"

# CRUD prose tests 3–9, 11, 12, 15, 16 for MongoClient.bulkWrite
# (specifications/source/crud/tests/README.md). UTF does not cover batch split.

private DB  = "client_bw_prose"
private COLL = "coll"
private NS   = "#{DB}.#{COLL}"

private def seq_len(command : BSON, key : String) : Int32
  case value = command[key]?
  when BSON
    n = 0
    value.each { n += 1 }
    n
  when Array
    value.size
  else
    0
  end
end

private def first_key(bson : BSON) : String?
  bson.each do |key, _value|
    return key
  end
  nil
end

private def ns0(command : BSON) : String?
  case value = command["nsInfo"]?
  when BSON
    value.each do |_, item|
      if doc = item.as?(BSON)
        return doc["ns"]?.as?(String)
      end
      break
    end
  end
  nil
end

private def bulk_started(events : Array(Mongo::Monitoring::Commands::CommandStartedEvent))
  events.select { |event| event.command_name == "bulkWrite" }
end

private def drop_coll(client : Mongo::Client, name : String = COLL)
  client[DB].command(Mongo::Commands::Drop, name: name) rescue nil
end

private def fail_off(client : Mongo::Client)
  client["admin"].command(
    Mongo::Commands::ConfigureFailPoint,
    fail_point: "failCommand",
    mode: "off",
  ) rescue nil
end

private def subscribe_started(client : Mongo::Client, events : Array(Mongo::Monitoring::Commands::CommandStartedEvent))
  client.subscribe_commands do |event|
    events << event if event.is_a?(Mongo::Monitoring::Commands::CommandStartedEvent)
  end
end

private def open_client(*, extra : String = "", one_host : Bool = false) : Mongo::Client
  base = ENV["MONGODB_URI"]
  base = mongodb_uri_one_host(base) if one_host
  opts = "serverSelectionTimeoutMS=8000"
  opts = "#{opts}&#{extra}" unless extra.empty?
  Mongo::Client.new(mongodb_uri_with(base, opts))
end

private def hello_or_pending(client : Mongo::Client) : Mongo::Commands::Hello::Result
  begin
    client.command(Mongo::Commands::Ping)
  rescue e : Mongo::Error::ServerSelection
    pending! "MongoDB is not reachable (#{e.message})"
  end
  hello = client.command(Mongo::Commands::Hello).as(Mongo::Commands::Hello::Result)
  pending! "needs MongoDB 8.0 (wire version 25)" if hello.max_wire_version < 25
  hello
end

describe "CRUD prose: client bulkWrite" do
  it "3. splits when models exceed maxWriteBatchSize" do
    client = open_client
    events = [] of Mongo::Monitoring::Commands::CommandStartedEvent
    begin
      hello = hello_or_pending(client)
      subscribe_started(client, events)
      drop_coll(client)
      n = hello.max_write_batch_size + 1
      models = [] of Mongo::ClientBulk::WriteModel
      n.times { models << Mongo::ClientBulk::InsertOne.new(NS, {a: "b"}) }
      result = client.bulk_write(models)
      result.inserted_count.should eq n
      started = bulk_started(events)
      started.size.should eq 2
      seq_len(started[0].command, "ops").should eq hello.max_write_batch_size
      seq_len(started[1].command, "ops").should eq 1
      started[0].operation_id.should eq started[1].operation_id
    ensure
      drop_coll(client)
      client.close
    end
  end

  it "4. splits when ops exceed maxMessageSizeBytes" do
    client = open_client
    events = [] of Mongo::Monitoring::Commands::CommandStartedEvent
    begin
      hello = hello_or_pending(client)
      subscribe_started(client, events)
      drop_coll(client)
      max_bson = hello.max_bson_object_size
      max_msg = hello.max_message_size_bytes
      num = max_msg // max_bson + 1
      models = [] of Mongo::ClientBulk::WriteModel
      num.times { models << Mongo::ClientBulk::InsertOne.new(NS, {a: "b" * (max_bson - 500)}) }
      result = client.bulk_write(models)
      result.inserted_count.should eq num
      started = bulk_started(events)
      started.size.should eq 2
      seq_len(started[0].command, "ops").should eq num - 1
      seq_len(started[1].command, "ops").should eq 1
      started[0].operation_id.should eq started[1].operation_id
    ensure
      drop_coll(client)
      client.close
    end
  end

  it "5. collects writeConcernErrors across batches" do
    client = open_client(extra: "retryWrites=false", one_host: true)
    events = [] of Mongo::Monitoring::Commands::CommandStartedEvent
    begin
      hello = hello_or_pending(client)
      subscribe_started(client, events)
      drop_coll(client)
      client["admin"].command(
        Mongo::Commands::ConfigureFailPoint,
        fail_point: "failCommand",
        mode: {times: 2},
        options: {
          data: {
            failCommands:      ["bulkWrite"],
            writeConcernError: {code: 91, errmsg: "Replication is being shut down"},
          },
        },
      )
      n = hello.max_write_batch_size + 1
      models = [] of Mongo::ClientBulk::WriteModel
      n.times { models << Mongo::ClientBulk::InsertOne.new(NS, {a: "b"}) }
      error = expect_raises(Mongo::Error::ClientBulkWrite) { client.bulk_write(models) }
      error.write_concern_errors.size.should eq 2
      error.partial_result.try(&.inserted_count).should eq n
      bulk_started(events).size.should eq 2
    ensure
      fail_off(client)
      drop_coll(client)
      client.close
    end
  end

  it "6. unordered collects writeErrors across batches; ordered stops" do
    client = open_client
    begin
      hello = hello_or_pending(client)
      n = hello.max_write_batch_size + 1
      drop_coll(client)
      client[DB][COLL].insert_one({_id: 1})

      events_u = [] of Mongo::Monitoring::Commands::CommandStartedEvent
      subscribe_started(client, events_u)
      models = [] of Mongo::ClientBulk::WriteModel
      n.times { models << Mongo::ClientBulk::InsertOne.new(NS, {_id: 1}) }
      unordered = expect_raises(Mongo::Error::ClientBulkWrite) { client.bulk_write(models, ordered: false) }
      unordered.write_errors.size.should eq n
      bulk_started(events_u).size.should eq 2

      drop_coll(client)
      client[DB][COLL].insert_one({_id: 1})
      events_o = [] of Mongo::Monitoring::Commands::CommandStartedEvent
      subscribe_started(client, events_o)
      ordered = expect_raises(Mongo::Error::ClientBulkWrite) { client.bulk_write(models, ordered: true) }
      ordered.write_errors.size.should eq 1
      bulk_started(events_o).size.should eq 1
    ensure
      drop_coll(client)
      client.close
    end
  end

  it "7. drains a cursor that needs getMore" do
    client = open_client
    events = [] of Mongo::Monitoring::Commands::CommandStartedEvent
    begin
      hello = hello_or_pending(client)
      subscribe_started(client, events)
      drop_coll(client)
      half = hello.max_bson_object_size // 2
      models = [
        Mongo::ClientBulk::UpdateOne.new(NS, {_id: "a" * half}, BSON.new({"$set" => {"x" => 1}}), upsert: true),
        Mongo::ClientBulk::UpdateOne.new(NS, {_id: "b" * half}, BSON.new({"$set" => {"x" => 1}}), upsert: true),
      ] of Mongo::ClientBulk::WriteModel
      result = client.bulk_write(models, verbose_results: true)
      result.upserted_count.should eq 2
      result.update_results.try(&.size).should eq 2
      events.any? { |event| event.command_name == "getMore" }.should eq true
    ensure
      drop_coll(client)
      client.close
    end
  end

  unless ENV["TOPOLOGY"]? == "standalone"
    it "8. drains getMore inside a transaction" do
      client = open_client
      events = [] of Mongo::Monitoring::Commands::CommandStartedEvent
      session = nil.as(Mongo::Session::ClientSession?)
      begin
        hello = hello_or_pending(client)
        subscribe_started(client, events)
        drop_coll(client)
        txn_session = client.start_session
        session = txn_session
        txn_session.start_transaction
        half = hello.max_bson_object_size // 2
        models = [
          Mongo::ClientBulk::UpdateOne.new(NS, {_id: "a" * half}, BSON.new({"$set" => {"x" => 1}}), upsert: true),
          Mongo::ClientBulk::UpdateOne.new(NS, {_id: "b" * half}, BSON.new({"$set" => {"x" => 1}}), upsert: true),
        ] of Mongo::ClientBulk::WriteModel
        result = client.bulk_write(models, verbose_results: true, session: txn_session)
        result.upserted_count.should eq 2
        result.update_results.try(&.size).should eq 2
        events.any? { |event| event.command_name == "getMore" }.should eq true
        txn_session.commit_transaction
      ensure
        if txn = session
          txn.end
        end
        drop_coll(client)
        client.close
      end
    end
  end

  it "9. handles a getMore error and kills the cursor" do
    client = open_client(one_host: true)
    events = [] of Mongo::Monitoring::Commands::CommandStartedEvent
    begin
      hello = hello_or_pending(client)
      subscribe_started(client, events)
      drop_coll(client)
      client["admin"].command(
        Mongo::Commands::ConfigureFailPoint,
        fail_point: "failCommand",
        mode: {times: 1},
        options: {
          data: {
            failCommands: ["getMore"],
            errorCode:    8,
          },
        },
      )
      half = hello.max_bson_object_size // 2
      models = [
        Mongo::ClientBulk::UpdateOne.new(NS, {_id: "a" * half}, BSON.new({"$set" => {"x" => 1}}), upsert: true),
        Mongo::ClientBulk::UpdateOne.new(NS, {_id: "b" * half}, BSON.new({"$set" => {"x" => 1}}), upsert: true),
      ] of Mongo::ClientBulk::WriteModel
      error = expect_raises(Mongo::Error::ClientBulkWrite) { client.bulk_write(models, verbose_results: true) }
      inner = error.error
      inner.should be_a(Mongo::Error::Command)
      if cmd = inner.as?(Mongo::Error::Command)
        cmd.code.should eq 8
      end
      error.partial_result.try(&.upserted_count).should eq 2
      error.partial_result.try(&.update_results).try(&.size).should eq 1
      events.any? { |event| event.command_name == "getMore" }.should eq true
      events.any? { |event| event.command_name == "killCursors" }.should eq true
    ensure
      fail_off(client)
      drop_coll(client)
      client.close
    end
  end

  # Official CRUD prose uses namespace "db.coll". A longer name makes nsInfo
  # larger than the 21-byte budget in the size formula, so the extra same-namespace
  # op would not fit and both cases would split.
  it "11. splits when a new namespace makes nsInfo too large" do
    client = open_client
    spec_ns = "db.coll"
    new_coll = "c" * 200
    new_ns = "db.#{new_coll}"
    begin
      hello = hello_or_pending(client)
      max_bson = hello.max_bson_object_size
      max_msg = hello.max_message_size_bytes
      ops_bytes = max_msg - 1122
      num_models = ops_bytes // max_bson
      remainder = ops_bytes % max_bson
      models = [] of Mongo::ClientBulk::WriteModel
      num_models.times { models << Mongo::ClientBulk::InsertOne.new(spec_ns, {a: "b" * (max_bson - 57)}) }
      if remainder >= 217
        num_models += 1
        models << Mongo::ClientBulk::InsertOne.new(spec_ns, {a: "b" * (remainder - 57)})
      end

      client["db"].command(Mongo::Commands::Drop, name: "coll") rescue nil
      events_same = [] of Mongo::Monitoring::Commands::CommandStartedEvent
      subscribe_started(client, events_same)
      same = models.dup
      same << Mongo::ClientBulk::InsertOne.new(spec_ns, {a: "b"})
      same_result = client.bulk_write(same)
      same_result.inserted_count.should eq num_models + 1
      same_started = bulk_started(events_same)
      same_started.size.should eq 1
      seq_len(same_started[0].command, "ops").should eq num_models + 1
      seq_len(same_started[0].command, "nsInfo").should eq 1
      ns0(same_started[0].command).should eq spec_ns

      client["db"].command(Mongo::Commands::Drop, name: "coll") rescue nil
      client["db"].command(Mongo::Commands::Drop, name: new_coll) rescue nil
      events_new = [] of Mongo::Monitoring::Commands::CommandStartedEvent
      subscribe_started(client, events_new)
      other = models.dup
      other << Mongo::ClientBulk::InsertOne.new(new_ns, {a: "b"})
      other_result = client.bulk_write(other)
      other_result.inserted_count.should eq num_models + 1
      new_started = bulk_started(events_new)
      new_started.size.should eq 2
      seq_len(new_started[0].command, "ops").should eq num_models
      seq_len(new_started[0].command, "nsInfo").should eq 1
      ns0(new_started[0].command).should eq spec_ns
      seq_len(new_started[1].command, "ops").should eq 1
      seq_len(new_started[1].command, "nsInfo").should eq 1
      ns0(new_started[1].command).should eq new_ns
    ensure
      client["db"].command(Mongo::Commands::Drop, name: "coll") rescue nil
      client["db"].command(Mongo::Commands::Drop, name: new_coll) rescue nil
      client.close
    end
  end

  it "12. returns a client error when one op cannot fit" do
    client = open_client
    begin
      hello = hello_or_pending(client)
      max_msg = hello.max_message_size_bytes
      expect_raises(Mongo::Error::Client) do
        client.bulk_write([
          Mongo::ClientBulk::InsertOne.new(NS, {a: "b" * max_msg}),
        ] of Mongo::ClientBulk::WriteModel)
      end
      expect_raises(Mongo::Error::Client) do
        client.bulk_write([
          Mongo::ClientBulk::InsertOne.new("db." + ("c" * max_msg), {a: "b"}),
        ] of Mongo::ClientBulk::WriteModel)
      end
    ensure
      client.close
    end
  end

  it "15. unacknowledged write concern is w:0 on every batch" do
    # Sharded: one mongos so countDocuments sees the same router as the w:0 writes (DRIVERS-2921).
    client = open_client(one_host: true)
    events = [] of Mongo::Monitoring::Commands::CommandStartedEvent
    begin
      hello = hello_or_pending(client)
      subscribe_started(client, events)
      drop_coll(client)
      client[DB].command(Mongo::Commands::Create, name: COLL)
      max_bson = hello.max_bson_object_size
      max_msg = hello.max_message_size_bytes
      num = max_msg // max_bson + 1
      models = [] of Mongo::ClientBulk::WriteModel
      num.times { models << Mongo::ClientBulk::InsertOne.new(NS, {a: "b" * (max_bson - 500)}) }
      result = client.bulk_write(models, ordered: false, write_concern: Mongo::WriteConcern.new(w: 0))
      result.acknowledged.should eq false
      started = bulk_started(events)
      started.size.should eq 2
      seq_len(started[0].command, "ops").should eq max_msg // max_bson
      seq_len(started[1].command, "ops").should eq 1
      started[0].operation_id.should eq started[1].operation_id
      started.each do |event|
        wc = event.command["writeConcern"]?.as?(BSON)
        wc.try(&.["w"]?).should eq 0
      end
      client[DB][COLL].count_documents.should eq num.to_i64
    ensure
      drop_coll(client)
      client.close
    end
  end

  it "16. generated _id is the first field" do
    client = open_client
    events = [] of Mongo::Monitoring::Commands::CommandStartedEvent
    begin
      hello_or_pending(client)
      subscribe_started(client, events)
      drop_coll(client)

      model = Mongo::ClientBulk::InsertOne.new(NS, {x: 1})
      first_key(model.document).should eq "_id"
      client.bulk_write([model] of Mongo::ClientBulk::WriteModel)
      bulk = bulk_started(events).last?
      bulk.should_not be_nil
      if event = bulk
        ops = event.command["ops"]?.as?(BSON)
        ops.should_not be_nil
        if ops_doc = ops
          op_doc = nil.as(BSON?)
          ops_doc.each { |_, item| op_doc = item.as?(BSON); break }
          doc = op_doc.try(&.["document"]?).try(&.as?(BSON))
          doc.should_not be_nil
          first_key(doc.as(BSON)).should eq "_id" if doc
        end
      end

      events.clear
      client[DB][COLL].insert_one({x: 1})
      insert = events.find { |event| event.command_name == "insert" }
      insert.should_not be_nil
      if event = insert
        docs = event.command["documents"]?.as?(BSON)
        if docs
          first = nil.as(BSON?)
          docs.each { |_, item| first = item.as?(BSON); break }
          first_key(first.as(BSON)).should eq "_id" if first
        end
      end

      events.clear
      bulk_op = client[DB][COLL].bulk
      bulk_op.insert_one({x: 1})
      bulk_op.execute
      insert2 = events.find { |event| event.command_name == "insert" }
      insert2.should_not be_nil
      if event = insert2
        docs = event.command["documents"]?.as?(BSON)
        if docs
          first = nil.as(BSON?)
          docs.each { |_, item| first = item.as?(BSON); break }
          first_key(first.as(BSON)).should eq "_id" if first
        end
      end
    ensure
      drop_coll(client)
      client.close
    end
  end
end
