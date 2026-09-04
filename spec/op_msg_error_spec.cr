require "./spec_helper"

# GitHub arm/macOS standalone SIGSEGV/SIGBUS in OpMsg#error? after BufferPool
# checkin (UTF disable_fail_points / ConfigureFailPoint mode=off). Nested []?
# is a BSON.view. BSON.new(BSON) does not copy.

private def serialize_op_msg(doc : BSON) : Bytes
  msg = Mongo::Messages::OpMsg.new(doc)
  io = IO::Memory.new
  msg.to_io(io)
  io.to_slice.clone
end

private def op_msg_header(body_size : Int32) : Mongo::Messages::Header
  Mongo::Messages::Header.new(
    message_length: 16 + body_size,
    request_id: 1,
    response_to: 1,
    op_code: Mongo::Messages::OpCode::Msg
  )
end

# Larger than BufferPool.checkin max so a scribbled slice is not shared.
private def parse_op_msg_scribble(doc : BSON) : Mongo::Messages::OpMsg
  body = serialize_op_msg(doc)
  buf = Bytes.new(1_048_577)
  body.copy_to(buf[0, body.size])
  msg = Mongo::Messages::OpMsg.new(buf, op_msg_header(body.size), used: body.size)
  buf.fill(0xFF)
  msg
end

describe Mongo::Messages::OpMsg do
  it "walks error? after the receive buffer is overwritten (ok: 1)" do
    doc = BSON.new({"ok" => 1.0})
    n = Mongo::Messages::BufferPool::POOL_SIZE * 4
    n.times do
      msg = parse_op_msg_scribble(doc)
      msg.error?.should be_nil
      msg.body["ok"].should eq 1.0
    end
  end

  it "keeps Command nested BSON after the parent buffer dies" do
    doc = BSON.build do |b|
      b["ok"] = 0.0
      b["errmsg"] = "failed"
      b["code"] = 123
      b["codeName"] = "Failed"
      b.document("errInfo") { b["reason"] = "nested" }
      b.document("topologyVersion") do
        b["processId"] = BSON::ObjectId.new
        b["counter"] = 1_i64
      end
      b.array("errorLabels") { b["0"] = "RetryableError" }
    end

    err = parse_op_msg_scribble(doc).error?
    GC.collect
    err.should be_a(Mongo::Error::Command)
    if err.is_a?(Mongo::Error::Command)
      err.code.should eq 123
      err.has_error_label?("RetryableError").should be_true
      details = err.details
      details.should_not be_nil
      if details
        details["reason"].should eq "nested"
      end
      topology = err.topology_version
      topology.should_not be_nil
      if topology
        topology["counter"].should eq 1_i64
      end
      reply = err.reply
      reply.should_not be_nil
      if reply
        reply["errmsg"].should eq "failed"
      end
    end
  end

  it "keeps CommandWrite nested BSON after the parent buffer dies" do
    doc = BSON.build do |b|
      b["ok"] = 1.0
      b.array("writeErrors") do
        b.document("0") do
          b["index"] = 0
          b["code"] = 11000
          b["errmsg"] = "E11000 duplicate key"
          b.document("errInfo") { b["field"] = "x" }
        end
      end
      b.document("topologyVersion") do
        b["processId"] = BSON::ObjectId.new
        b["counter"] = 2_i64
      end
    end

    err = parse_op_msg_scribble(doc).error?
    GC.collect
    err.should be_a(Mongo::Error::CommandWrite)
    if err.is_a?(Mongo::Error::CommandWrite)
      first = err.errors.first?
      first.should_not be_nil
      if first
        first.code.should eq 11000
        details = first.details
        details.should_not be_nil
        if details
          details["field"].should eq "x"
        end
        topology = first.topology_version
        topology.should_not be_nil
        if topology
          topology["counter"].should eq 2_i64
        end
      end
    end
  end

  it "keeps WriteConcern nested BSON after the parent buffer dies" do
    doc = BSON.build do |b|
      b["ok"] = 1.0
      b.document("writeConcernError") do
        b["code"] = 64
        b["codeName"] = "WriteConcernFailed"
        b["errmsg"] = "waiting for replication"
        b.document("errInfo") { b["n"] = 1 }
        b.array("errorLabels") { b["0"] = "RetryableWriteError" }
      end
    end

    err = parse_op_msg_scribble(doc).error?
    GC.collect
    err.should be_a(Mongo::Error::WriteConcern)
    if err.is_a?(Mongo::Error::WriteConcern)
      err.code.should eq 64
      err.has_error_label?("RetryableWriteError").should be_true
      details = err.details
      details.should_not be_nil
      if details
        details["n"].should eq 1
      end
    end
  end

  it "reuses BufferPool-sized receive buffers for error?" do
    doc = BSON.new({"ok" => 1.0})
    body = serialize_op_msg(doc)
    header = op_msg_header(body.size)
    n = Mongo::Messages::BufferPool::POOL_SIZE * 4
    n.times do
      buf = Bytes.new(Mongo::Messages::BufferPool::DEFAULT_SIZE)
      body.copy_to(buf[0, body.size])
      msg = Mongo::Messages::OpMsg.new(buf, header, used: body.size)
      msg.error?.should be_nil
      msg.body["ok"].should eq 1.0
    end
  end
end

describe "ConfigureFailPoint mode=off then another command" do
  it "does not SIGSEGV after BufferPool reuse" do
    Mongo::SpecCluster.exclusive do
      uri = mongodb_uri_direct(ENV["MONGODB_URI"])
      client = Mongo::Client.new(mongodb_uri_with(uri, "serverSelectionTimeoutMS=5000&appName=wave33-failpoint-off"))
      begin
        begin
          client.command(Mongo::Commands::Ping)
        rescue e : Mongo::Error::ServerSelection
          pending! "MongoDB is not reachable (#{e.message})"
        end

        n = Mongo::Messages::BufferPool::POOL_SIZE * 4
        n.times do
          begin
            client.command(
              Mongo::Commands::ConfigureFailPoint,
              database: "admin",
              fail_point: "failCommand",
              mode: "off"
            )
          rescue Mongo::Error::Server
            # UTF send_fail_point_off also rescues. error? already walked the
            # reply (ok:1 mode=off, or ok:0 when test commands are off).
          end
          GC.collect
          client.command(Mongo::Commands::Ping)
        end
      ensure
        client.close
      end
    end
  end
end
