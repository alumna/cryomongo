require "./spec_helper"

describe Mongo::Compression do
  it "round-trips zlib payload" do
    src = Bytes.new(64) { |i| (i * 3).to_u8 }
    io = IO::Memory.new
    Mongo::Compression.deflate(Mongo::Compression::Id::Zlib, src, io, 6)
    io.rewind
    compressed = io.to_slice
    out = Mongo::Compression.inflate(Mongo::Compression::Id::Zlib, compressed, src.size)
    out.should eq src
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
    Mongo::Compression.negotiate(["zlib"], ["snappy"]).should be_nil
    Mongo::Compression.negotiate([] of String, ["zlib"]).should be_nil
  end
end

describe Mongo::Messages::OpMsg do
  it "parses an OP_MSG body after OP_COMPRESSED inflate" do
    inner = Mongo::Messages::OpMsg.new({ping: 1, "$db": "admin"})
    uncompressed = IO::Memory.new
    inner.to_io(uncompressed)
    body = uncompressed.to_slice

    compressed = IO::Memory.new
    Mongo::Compression.deflate(Mongo::Compression::Id::Zlib, body, compressed, 6)

    frame = IO::Memory.new
    # originalOpcode, uncompressedSize, compressorId, payload
    frame.write_bytes(Mongo::Messages::OpCode::Msg.value, IO::ByteFormat::LittleEndian)
    frame.write_bytes(body.size, IO::ByteFormat::LittleEndian)
    frame.write_byte(Mongo::Compression::Id::Zlib.value)
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
end
