require "bson"
require "./message_part"
require "./op_code"

# The OP_REPLY message is sent by the database in response to an OP_QUERY or OP_GET_MORE message.
struct Mongo::Messages::OpReply < Mongo::Messages::Part
  @[Field(ignore: true)]
  @op_code : OpCode = OpCode::Reply

  @[Flags]
  enum ResponseFlags : Int32
    CursorNotFound
    QueryFailure
    ShardConfigStale
    AwaitCapable
  end

  getter response_flags : ResponseFlags
  getter cursor_id : Int64
  getter starting_from : Int32
  getter number_returned : Int32
  getter documents : Array(BSON)

  def initialize(
    @response_flags,
    @cursor_id,
    @starting_from,
    @number_returned,
    @documents,
  )
  end

  def initialize(io : IO, header : Messages::Header)
    size = header.body_size
    msg_bytes = Bytes.new(size)
    io.read_fully(msg_bytes)
    msg_view = IO::Memory.new(msg_bytes, writeable: false)

    @response_flags = ResponseFlags.from_value(msg_view.read_bytes(Int32, IO::ByteFormat::LittleEndian))
    @cursor_id = msg_view.read_bytes(Int64, IO::ByteFormat::LittleEndian)
    @starting_from = msg_view.read_bytes(Int32, IO::ByteFormat::LittleEndian)
    @number_returned = msg_view.read_bytes(Int32, IO::ByteFormat::LittleEndian)

    @documents = [] of BSON

    while msg_view.pos < size
      @documents << BSON.new(msg_view)
    end
  end
end
