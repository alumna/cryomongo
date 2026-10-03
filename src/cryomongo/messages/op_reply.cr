require "bson"
require "./message_part"
require "./op_code"
require "./owned_receive"

# The OP_REPLY message is sent by the database in response to an OP_QUERY or OP_GET_MORE message.
# Class, same as OpMsg: receive copies this out of Message. A class field
# on a struct is not a Darwin GC root (Wave 47). Wave 55: documents are
# viewed through OwnedReceive#view (pin.bytes), not only an ensure pin.
class Mongo::Messages::OpReply < Mongo::Messages::Part
  @[Field(ignore: true)]
  @op_code : OpCode = OpCode::Reply

  # Same heap owner as OpMsg: wrap the owned receive copy in a class so
  # Darwin GC scans it while documents are BSON.view interior slices.
  # Keep this on the class (Wave 52). Outgoing replies leave this nil.
  @[Field(ignore: true)]
  @frame : OwnedReceive? = nil

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
  @documents : Array(BSON)

  def documents : Array(BSON)
    pin = @frame
    docs = @documents
    return docs unless owner = pin
    # Re-view each doc from pin.bytes so the owner stays a GC root
    # (Wave 55). A pin only in ensure is dropped. Same slices, no
    # second array.
    i = 0
    while i < docs.size
      doc = docs[i]
      docs[i] = owner.view(doc.data)
      i += 1
    end
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

  # *msg_bytes* must stay valid for the life of this message. Wrap it in
  # OwnedReceive on this class. Do not checkin here (the IO path already
  # returned the staging buffer after the copy).
  def initialize(msg_bytes : Bytes, header : Messages::Header, used : Int32 = msg_bytes.size)
    owner = OwnedReceive.new(msg_bytes)
    @frame = owner
    view_bytes = owner.bytes[0, used]
    msg_view = IO::Memory.new(view_bytes, writable: false)

    @response_flags = ResponseFlags.from_value(msg_view.read_bytes(Int32, IO::ByteFormat::LittleEndian))
    @cursor_id = msg_view.read_bytes(Int64, IO::ByteFormat::LittleEndian)
    @starting_from = msg_view.read_bytes(Int32, IO::ByteFormat::LittleEndian)
    @number_returned = msg_view.read_bytes(Int32, IO::ByteFormat::LittleEndian)

    @documents = [] of BSON

    while msg_view.pos < used
      payload = Messages.read_bson_view(view_bytes, msg_view)
      @documents << owner.view(payload.data)
    end
  end
end
