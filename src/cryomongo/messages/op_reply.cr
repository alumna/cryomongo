require "bson"
require "./message_part"
require "./op_code"

# The OP_REPLY message is sent by the database in response to an OP_QUERY or OP_GET_MORE message.
struct Mongo::Messages::OpReply < Mongo::Messages::Part
  @[Field(ignore: true)]
  @op_code : OpCode = OpCode::Reply

  # Same GC root as OpMsg: keep the owned receive copy while documents
  # are BSON.view interior slices. Outgoing replies leave this nil.
  @[Field(ignore: true)]
  @frame : Bytes? = nil

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

  def documents : Array(BSON)
    pin = @frame
    docs = @documents
    # Load @frame so the compiler keeps the GC root on this struct.
    pin.try(&.size)
    docs
  end

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
    msg_bytes = Messages::BufferPool.checkout(size)
    begin
      Messages.read_exact(io, msg_bytes[0, size])
    rescue error
      Messages::BufferPool.checkin(msg_bytes)
      raise error
    end
    # Same receive pattern as OpMsg: copy, checkin, then BSON.view the copy.
    initialize(Messages::BufferPool.copy_and_checkin(msg_bytes, size), header, used: size)
  end

  # *msg_bytes* must stay valid for the life of this message. Store it in
  # @frame so Darwin GC keeps the base pointer. Do not checkin here (the IO
  # path already returned the staging buffer after the copy).
  def initialize(msg_bytes : Bytes, header : Messages::Header, used : Int32 = msg_bytes.size)
    @frame = msg_bytes
    view_bytes = msg_bytes[0, used]
    msg_view = IO::Memory.new(view_bytes, writable: false)

    @response_flags = ResponseFlags.from_value(msg_view.read_bytes(Int32, IO::ByteFormat::LittleEndian))
    @cursor_id = msg_view.read_bytes(Int64, IO::ByteFormat::LittleEndian)
    @starting_from = msg_view.read_bytes(Int32, IO::ByteFormat::LittleEndian)
    @number_returned = msg_view.read_bytes(Int32, IO::ByteFormat::LittleEndian)

    @documents = [] of BSON

    while msg_view.pos < used
      @documents << Messages.read_bson_view(view_bytes, msg_view)
    end
  end
end
