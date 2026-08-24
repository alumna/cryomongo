require "./spec_helper"

private def round_trip(id : Mongo::Compression::Id, src : Bytes, zlib_level = 6)
  io = IO::Memory.new
  Mongo::Compression.deflate(id, src, io, zlib_level)
  io.rewind
  Mongo::Compression.inflate(id, io.to_slice, src.size)
end

describe Mongo::Compression do
  it "round-trips zlib payload" do
    src = Bytes.new(64) { |i| (i * 3).to_u8 }
    round_trip(Mongo::Compression::Id::Zlib, src).should eq src
  end

  it "round-trips snappy payload" do
    src = Bytes.new(64) { |i| (i * 3).to_u8 }
    round_trip(Mongo::Compression::Id::Snappy, src).should eq src
  end

  it "round-trips zstd payload" do
    src = Bytes.new(64) { |i| (i * 3).to_u8 }
    round_trip(Mongo::Compression::Id::Zstd, src).should eq src
  end

  it "round-trips a large snappy payload" do
    src = Bytes.new(80_000) { |i| (i & 0xff).to_u8 }
    round_trip(Mongo::Compression::Id::Snappy, src).should eq src
  end

  it "does not compress hello or saslStart" do
    Mongo::Compression.forbidden?("hello").should be_true
    Mongo::Compression.forbidden?("isMaster").should be_true
    Mongo::Compression.forbidden?("saslStart").should be_true
    Mongo::Compression.forbidden?("ping").should be_false
    Mongo::Compression.forbidden?("insert").should be_false
  end

  it "picks the first client compressor the server also has" do
    id = Mongo::Compression.negotiate(["zlib"], ["snappy", "zlib"])
    id.should eq Mongo::Compression::Id::Zlib
    Mongo::Compression.negotiate(["snappy", "zlib"], ["snappy", "zlib"]).should eq Mongo::Compression::Id::Snappy
    Mongo::Compression.negotiate(["zlib"], ["snappy"]).should be_nil
    Mongo::Compression.negotiate([] of String, ["zlib"]).should be_nil
  end
end

describe Mongo::Messages::OpMsg do
  it "parses an OP_MSG body after zlib OP_COMPRESSED inflate" do
    parse_compressed_op_msg(Mongo::Compression::Id::Zlib)
  end

  it "parses an OP_MSG body after snappy OP_COMPRESSED inflate" do
    parse_compressed_op_msg(Mongo::Compression::Id::Snappy)
  end

  it "parses an OP_MSG body after zstd OP_COMPRESSED inflate" do
    parse_compressed_op_msg(Mongo::Compression::Id::Zstd)
  end
end

private def parse_compressed_op_msg(id : Mongo::Compression::Id)
  inner = Mongo::Messages::OpMsg.new({ping: 1, "$db": "admin"})
  uncompressed = IO::Memory.new
  inner.to_io(uncompressed)
  body = uncompressed.to_slice

  compressed = IO::Memory.new
  Mongo::Compression.deflate(id, body, compressed, 6)

  frame = IO::Memory.new
  # originalOpcode, uncompressedSize, compressorId, payload
  frame.write_bytes(Mongo::Messages::OpCode::Msg.value, IO::ByteFormat::LittleEndian)
  frame.write_bytes(body.size, IO::ByteFormat::LittleEndian)
  frame.write_byte(id.value)
  frame.write(compressed.to_slice)

  header = Mongo::Messages::Header.new(
    message_length: 16 + frame.bytesize,
    request_id: 1,
    response_to: 1,
    op_code: Mongo::Messages::OpCode::Compressed
  )
  frame.rewind
  inner_header, plain = Mongo::Messages.read_compressed(frame, header)
  inner_header.op_code.msg?.should be_true
  msg = Mongo::Messages::OpMsg.new(plain, inner_header)
  msg.body["ping"].should eq 1
end
