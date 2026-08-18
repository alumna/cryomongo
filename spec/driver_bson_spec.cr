require "./spec_helper"

describe "Driver use of BSON 0.8.0" do
  it "reads hello lastWriteDate as Time through Serializable" do
    ms = Time.utc(2020, 1, 2, 3, 4, 5).to_unix_ms
    hello = BSON.build do |b|
      b["ok"] = 1.0
      b["ismaster"] = true
      b["minWireVersion"] = 0
      b["maxWireVersion"] = 25
      b["lastWrite"] = BSON.build { |w|
        w["lastWriteDate"] = BSON::DateTime.new(ms)
        w["opTime"] = BSON.new({ts: BSON::Timestamp.new(1_u32, 1_u32), t: 1_i64})
      }
    end

    result = Mongo::Commands::Hello::Result.from_bson(hello)
    last_write = result.last_write
    last_write.should_not be_nil
    if last_write
      last_write.last_write_date.should eq Time.unix_ms(ms)
      last_write.op_time.should be_a(BSON)
    end

    desc = Mongo::SDAM::ServerDescription.new("localhost:27017", result, 1.millisecond)
    desc.last_write_date.should eq Time.unix_ms(ms)
  end

  it "converts BSON::DateTime and Time with Tools.as_time?" do
    time = Time.utc(2021, 6, 1, 12, 0, 0)
    Mongo::Tools.as_time?(time).should eq time
    Mongo::Tools.as_time?(BSON::DateTime.new(time)).should eq time
    Mongo::Tools.as_time?("nope").should be_nil
  end

  it "builds command options with one append" do
    body, sequences = Mongo::Commands.make({
      ping:  1,
      "$db": "admin",
    }, {
      max_time_ms:     50,
      read_preference: Mongo::PRIMARY_READ_PREFERENCE,
      comment:         "x",
      unused:          nil,
    })
    sequences.should be_nil
    body["ping"].should eq 1
    body["$db"].should eq "admin"
    body["maxTimeMS"].should eq 50
    body["$readPreference"].should be_a(BSON)
    body["comment"].should eq "x"
    body.has_key?("unused").should be_false
  end

  it "merges write fields with one append" do
    doc = Mongo::Tools.merge_bson({
      q:     BSON.new({a: 1}),
      limit: 1,
    }, {
      collation: Mongo::Collation.new(locale: "en"),
      hint:      nil,
    })
    doc["limit"].should eq 1
    doc["collation"].should be_a(BSON)
    doc.has_key?("hint").should be_false
  end

  it "copy_with writes overrides in one pass" do
    source = BSON.new({a: 1, b: 2})
    copy = source.copy_with({b: 3, c: 4})
    copy["a"].should eq 1
    copy["b"].should eq 3
    copy["c"].should eq 4
    source["b"].should eq 2
  end

  it "reads a document as a view of an existing buffer" do
    doc = BSON.new({ok: 1.0, n: 2})
    buffer = doc.data
    io = IO::Memory.new(buffer, writable: false)
    view = Mongo::Messages.read_bson_view(buffer, io)
    view["ok"].should eq 1.0
    view["n"].should eq 2
    io.pos.should eq buffer.size
  end

  it "does not mutate the live OP_MSG body in safe_payload" do
    body = BSON.new({ping: 1, "$db": "admin"})
    msg = Mongo::Messages::OpMsg.new(body)
    payload = msg.safe_payload(Mongo::Commands::Ping)
    payload["ping"].should eq 1
    msg.body.has_key?("documents").should be_false
  end
end
