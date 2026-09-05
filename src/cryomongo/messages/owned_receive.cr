# Heap owner for an OP_MSG / OP_REPLY receive copy.
# Bytes is a Slice struct (pointer + size). @frame : Bytes? on OpMsg /
# OpReply (also structs) is not a Darwin GC root: LLVM can keep the struct
# in a register, Darwin GC misses the interior pointer, and error? then
# walks a freed BSON.view (Wave 42 SIGBUS). A class instance is a heap
# object. A struct field that holds a class pointer is a GC root.
class Mongo::Messages::OwnedReceive
  getter bytes : Bytes

  def initialize(@bytes : Bytes)
  end
end
