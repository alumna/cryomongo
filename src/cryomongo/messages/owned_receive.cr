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
# stays a GC root. bson.cr document is a class (Wave 58) so `[]?` is a
# method on a heap object. Do not clone.
#
# Wave 62: LLVM can still drop this class after #view returns. BSON
# `@data` aliases `@bytes` (ubuntu-22.04-arm SIGSEGV in BSON#fetch
# during Drop, run 34024439035). Do not clone every hello.
#
# Wave 63: `pin_after(view(body.data)[key]?)` evaluates `[]?` **before**
# entering pin_after (Crystal argument order). GitHub `34141211854`
# ubuntu-26.04-arm standalone SIGSEGV and macos-26 standalone SIGBUS in
# BSON#fetch during insert error? (`0x…0002`), stack still in #fetch.
# Keep #fetch / #must_fetch NoInline. Hold `self` (this class) across
# `[]?`; a `Bytes` / Slice local is not a GC root. Do not wrap the walk
# as a pin argument. A pin only in ensure is dropped (Wave 55).
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

  # []? through #view. NoInline so this class stays a GC root for the
  # whole []? (Wave 63). Hold `self` across the walk: `keep = @bytes` is
  # a Slice and is not a root. Do not wrap []? as pin_after's argument.
  @[NoInline]
  def fetch(body : BSON, key : String)
    owner = self
    viewed = view(body.data)
    result = viewed[key]?
    owner.bytes.size
    result
  end

  # [] through #view. Raises when *key* is missing (same as BSON#[]).
  @[NoInline]
  def must_fetch(body : BSON, key : String)
    owner = self
    viewed = view(body.data)
    result = viewed[key]
    owner.bytes.size
    result
  end
end
