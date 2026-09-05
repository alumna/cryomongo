require "./spec_helper"

# GitHub arm/macOS standalone SIGSEGV/SIGBUS in OpMsg#error? after BufferPool
# checkin (UTF disable_fail_points / ConfigureFailPoint mode=off). Nested []?
# is a BSON.view. BSON.new(BSON) does not copy. Wave 33 scribbled AFTER parse
# on one fiber and did not prove preview_mt pool reuse.

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

private def op_reply_header(body_size : Int32) : Mongo::Messages::Header
  Mongo::Messages::Header.new(
    message_length: 16 + body_size,
    request_id: 1,
    response_to: 1,
    op_code: Mongo::Messages::OpCode::Reply
  )
end

# IO receive path: pool checkout, copy, checkin, then BSON.view of the copy.
private def parse_op_msg_via_pool(doc : BSON) : Mongo::Messages::OpMsg
  body = serialize_op_msg(doc)
  Mongo::Messages::OpMsg.new(IO::Memory.new(body), op_msg_header(body.size))
end

# Hold every pooled slot, fill 0xFF, then checkin. A view of the staging
# buffer would die. The owned copy must still parse.
private def scribble_pooled_buffers : Nil
  n = Mongo::Messages::BufferPool::POOL_SIZE
  held = Array(Bytes).new(n)
  n.times do
    held << Mongo::Messages::BufferPool.checkout(Mongo::Messages::BufferPool::DEFAULT_SIZE)
  end
  held.each do |buf|
    buf.fill(0xFF)
    Mongo::Messages::BufferPool.checkin(buf)
  end
end

private def parse_op_msg_scribble(doc : BSON) : Mongo::Messages::OpMsg
  msg = parse_op_msg_via_pool(doc)
  scribble_pooled_buffers
  msg
end

private def serialize_op_reply(docs : Array(BSON)) : Bytes
  reply = Mongo::Messages::OpReply.new(
    Mongo::Messages::OpReply::ResponseFlags::None,
    0_i64,
    0,
    docs.size,
    docs
  )
  io = IO::Memory.new
  reply.to_io(io)
  io.to_slice.clone
end

private def ok1_with_topology : BSON
  BSON.build do |b|
    b["ok"] = 1.0
    b.document("topologyVersion") do
      b["processId"] = BSON::ObjectId.new
      b["counter"] = 1_i64
    end
  end
end

# Walk the same nested []? path error? uses. Raise so a spawned fiber can
# send the exception (spec DSL in spawn does not fail the example).
private def walk_op_msg_error(msg : Mongo::Messages::OpMsg, expect_command : Bool) : Nil
  err = msg.error?
  if expect_command
    raise "expected Command, got #{err.inspect}" unless err.is_a?(Mongo::Error::Command)
    details = err.details
    raise "expected errInfo" unless details
    reason = details["reason"]
    raise "expected nested reason, got #{reason.inspect}" unless reason == "nested"
  else
    raise "expected no error, got #{err.inspect}" if err
    ok = msg.body["ok"]
    raise "expected ok 1.0, got #{ok.inspect}" unless ok == 1.0
    tv = msg.body["topologyVersion"]?
    raise "expected topologyVersion BSON" unless tv.is_a?(BSON)
    counter = tv["counter"]
    raise "expected counter 1, got #{counter.inspect}" unless counter == 1_i64
  end
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

  # Wave 42: copy-then-checkin is not enough if the owned Bytes is only a
  # local. Darwin GC can free that allocation while error? walks interior
  # BSON.view slices. @frame on the message keeps the base pointer.
  it "walks error? and body after GC.collect (owned frame stays alive)" do
    ok_msg = parse_op_msg_via_pool(ok1_with_topology)
    err_doc = BSON.build do |b|
      b["ok"] = 0.0
      b["errmsg"] = "failed"
      b["code"] = 123
      b.document("errInfo") { b["reason"] = "nested" }
    end
    err_msg = parse_op_msg_via_pool(err_doc)
    32.times { Bytes.new(16_384) }
    GC.collect
    walk_op_msg_error(ok_msg, false)
    walk_op_msg_error(err_msg, true)
  end

  it "reuses BufferPool-sized receive buffers for error?" do
    doc = BSON.new({"ok" => 1.0})
    n = Mongo::Messages::BufferPool::POOL_SIZE * 4
    n.times do
      msg = parse_op_msg_via_pool(doc)
      msg.error?.should be_nil
      msg.body["ok"].should eq 1.0
    end
  end

  # preview_mt: another fiber checkouts and overwrites while parse / error?
  # still run. Cooperative spawn still covers copy-then-checkin when the
  # scribble fiber runs between parse and the nested walk.
  it "walks error? while another fiber overwrites BufferPool buffers" do
    ok_doc = ok1_with_topology
    err_doc = BSON.build do |b|
      b["ok"] = 0.0
      b["errmsg"] = "failed"
      b["code"] = 123
      b.document("errInfo") { b["reason"] = "nested" }
    end
    ok_body = serialize_op_msg(ok_doc)
    err_body = serialize_op_msg(err_doc)
    ok_header = op_msg_header(ok_body.size)
    err_header = op_msg_header(err_body.size)
    n = Mongo::Messages::BufferPool::POOL_SIZE * 8

    stop = Channel(Nil).new(1)
    started = Channel(Nil).new(1)
    stopped = Channel(Nil).new(1)
    spawn do
      started.send(nil)
      loop do
        select
        when stop.receive
          break
        else
          buf = Mongo::Messages::BufferPool.checkout(Mongo::Messages::BufferPool::DEFAULT_SIZE)
          buf.fill(0xFF)
          Mongo::Messages::BufferPool.checkin(buf)
          Fiber.yield
        end
      end
      stopped.send(nil)
    end
    started.receive

    failures = Channel(Exception?).new(2)
    2.times do
      spawn do
        begin
          n.times do
            ok_msg = Mongo::Messages::OpMsg.new(IO::Memory.new(ok_body), ok_header)
            walk_op_msg_error(ok_msg, false)
            err_msg = Mongo::Messages::OpMsg.new(IO::Memory.new(err_body), err_header)
            walk_op_msg_error(err_msg, true)
          end
          failures.send(nil)
        rescue e
          failures.send(e)
        end
      end
    end

    2.times do
      result = failures.receive
      result.should be_nil
    end
    stop.send(nil)
    stopped.receive
  end
end

describe Mongo::Messages::OpReply do
  it "keeps documents after BufferPool reuse" do
    nested = BSON.build do |b|
      b["ok"] = 1.0
      b.document("cursor") { b["id"] = 0_i64 }
    end
    body = serialize_op_reply([nested])
    msg = Mongo::Messages::OpReply.new(IO::Memory.new(body), op_reply_header(body.size))
    scribble_pooled_buffers
    first = msg.documents.first?
    first.should_not be_nil
    if first
      first["ok"].should eq 1.0
      cursor = first["cursor"]?
      cursor.should be_a(BSON)
      if cursor.is_a?(BSON)
        cursor["id"].should eq 0_i64
      end
    end
  end

  it "walks documents after GC.collect (owned frame stays alive)" do
    nested = BSON.build do |b|
      b["ok"] = 1.0
      b.document("cursor") { b["id"] = 0_i64 }
    end
    body = serialize_op_reply([nested])
    msg = Mongo::Messages::OpReply.new(IO::Memory.new(body), op_reply_header(body.size))
    32.times { Bytes.new(16_384) }
    GC.collect
    first = msg.documents.first?
    first.should_not be_nil
    if first
      first["ok"].should eq 1.0
      cursor = first["cursor"]?
      cursor.should be_a(BSON)
      if cursor.is_a?(BSON)
        cursor["id"].should eq 0_i64
      end
    end
  end
end

describe "ConfigureFailPoint mode=off then another command" do
  it "does not SIGSEGV after BufferPool reuse" do
    Mongo::SpecCluster.exclusive do
      uri = mongodb_uri_direct(ENV["MONGODB_URI"])
      client = Mongo::Client.new(mongodb_uri_with(uri, "serverSelectionTimeoutMS=5000&appName=wave38-failpoint-off"))
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
