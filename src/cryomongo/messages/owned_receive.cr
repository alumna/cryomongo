# Heap owner for an OP_MSG / OP_REPLY receive copy.
# Bytes is a Slice struct (pointer + size). @frame : Bytes? on a struct
# OpMsg is not a Darwin GC root (Wave 42). A class field on that struct
# is not enough either (Wave 47 OwnedReceive; GitHub macos-15 standalone
# still SIGBUS at error?+1604). Receive OpMsg / OpReply / Message are
# classes (Wave 52) so the GC scans the object. Keep this owner on the
# class. Do not checkin the owned copy.
#
# Wave 55: a pin only in ensure is dropped (ubuntu-26.04 SIGSEGV at
# error? during create_data_key insert). error? / body / stored-error
# must call #view / #fetch so the walk uses `@bytes` and this class
# stays a GC root. bson.cr stays a struct.
class Mongo::Messages::OwnedReceive
  getter bytes : Bytes

  def initialize(@bytes : Bytes)
  end

  # Interior BSON.view of *data* rebuilt from `@bytes`.
  # *data* is a slice of this owner (receive body or nested doc).
  # The walk names `@bytes` so LLVM cannot drop this class (Wave 55).
  # Do not clone.
  def view(data : Bytes) : BSON
    owned = @bytes
    origin = owned.to_unsafe.address
    ptr = data.to_unsafe.address
    last = ptr + data.size
    limit = origin + owned.size
    if ptr >= origin && last <= limit
      diff = ptr - origin
      if diff <= Int32::MAX
        return BSON.view(owned[diff.to_i32, data.size])
      end
    end
    BSON.view(data)
  end

  # []? through #view so the owner stays live for nested fetches.
  def fetch(body : BSON, key : String)
    view(body.data)[key]?
  end

  # [] through #view. Raises when *key* is missing (same as BSON#[]).
  def must_fetch(body : BSON, key : String)
    view(body.data)[key]
  end
end
