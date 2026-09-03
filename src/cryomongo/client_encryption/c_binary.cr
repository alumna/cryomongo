# Helpers for mongocrypt_binary_t. The C library copies input views. Output
# views live only until the parent ctx is destroyed, so we clone Bytes.
# :nodoc:
module Mongo::ClientEncryption::CBinary
  extend self

  # View *bytes* as a mongocrypt binary for the duration of the block.
  def with_bytes(bytes : Bytes, &)
    bin = LibMongoCrypt.binary_new_from_data(bytes.to_unsafe, bytes.size.to_u32)
    if bin.null?
      raise Mongo::Error::Crypt.new("mongocrypt_binary_new_from_data failed.")
    end
    begin
      yield bin
    ensure
      LibMongoCrypt.binary_destroy(bin)
    end
  end

  # Allocate an empty output binary, yield it, then copy the viewed bytes.
  def copy_out(&) : Bytes
    bin = LibMongoCrypt.binary_new
    if bin.null?
      raise Mongo::Error::Crypt.new("mongocrypt_binary_new failed.")
    end
    begin
      yield bin
      ptr = LibMongoCrypt.binary_data(bin)
      len = LibMongoCrypt.binary_len(bin)
      if ptr.null? || len == 0
        Bytes.empty
      else
        Slice.new(ptr, len.to_i).clone
      end
    ensure
      LibMongoCrypt.binary_destroy(bin)
    end
  end

  def crypt_message(crypt : LibMongoCrypt::Crypt) : {String, UInt32}
    message_from { |status| LibMongoCrypt.status(crypt, status) }
  end

  def ctx_message(ctx : LibMongoCrypt::Ctx) : {String, UInt32}
    message_from { |status| LibMongoCrypt.ctx_status(ctx, status) }
  end

  def raise_crypt(crypt : LibMongoCrypt::Crypt)
    message, code = crypt_message(crypt)
    raise Mongo::Error::Crypt.new(message, code: code)
  end

  def raise_ctx(ctx : LibMongoCrypt::Ctx)
    message, code = ctx_message(ctx)
    raise Mongo::Error::Crypt.new(message, code: code)
  end

  private def message_from(& : LibMongoCrypt::Status ->) : {String, UInt32}
    status = LibMongoCrypt.status_new
    if status.null?
      return {"libmongocrypt status_new failed.", 0_u32}
    end
    begin
      yield status
      ptr = LibMongoCrypt.status_message(status, Pointer(UInt32).null)
      message = ptr.null? ? "libmongocrypt error" : String.new(ptr)
      {message, LibMongoCrypt.status_code(status)}
    ensure
      LibMongoCrypt.status_destroy(status)
    end
  end
end
