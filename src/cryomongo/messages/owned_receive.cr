# Heap owner for an OP_MSG / OP_REPLY receive copy.
# Bytes is a Slice struct (pointer + size). @frame : Bytes? on a struct
# OpMsg is not a Darwin GC root (Wave 42). A class field on that struct
# is not enough either (Wave 47 OwnedReceive; GitHub macos-15 standalone
# still SIGBUS at error?+1604). Receive OpMsg / OpReply / Message are
# classes (Wave 52) so the GC scans the object. Keep this owner on the
# class. Do not checkin the owned copy.
class Mongo::Messages::OwnedReceive
  getter bytes : Bytes

  def initialize(@bytes : Bytes)
  end
end
