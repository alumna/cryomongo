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
    sized_io = IO::Sized.new(io, read_size: size)

    @response_flags = ResponseFlags.from_value Int32.from_io(sized_io, IO::ByteFormat::LittleEndian)
    @cursor_id = Int64.from_io(sized_io, IO::ByteFormat::LittleEndian)
    @starting_from = Int32.from_io(sized_io, IO::ByteFormat::LittleEndian)
    @number_returned = Int32.from_io(sized_io, IO::ByteFormat::LittleEndian)

    # Track exactly how many bytes the above integers consumed (4 + 8 + 4 + 4 = 20)
    bytes_read = 20
    @documents = [] of BSON

    # Stream the documents directly off the socket
    while bytes_read < size
      doc = BSON.new(sized_io)
      @documents << doc
      bytes_read += doc.size
    end
  end
end
