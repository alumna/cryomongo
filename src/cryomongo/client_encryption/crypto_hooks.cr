require "openssl"

lib LibCrypto
  fun evp_digest = EVP_Digest(data : Void*, count : SizeT, md : UInt8*, size : UInt*, type : EVP_MD, impl : Void*) : Int
end

# OpenSSL callbacks for nocrypto libmongocrypt (official Linux 1.20.4 tarball
# has no libcrypto NEEDED). libmongocrypt pads AES-CBC input to a block
# multiple before the hook, so OpenSSL padding stays off.
# :nodoc:
module Mongo::ClientEncryption::CryptoHooks
  extend self

  CBC_ENCRYPT = ->(_ctx : Void*, key : LibMongoCrypt::Binary, iv : LibMongoCrypt::Binary, input : LibMongoCrypt::Binary, output : LibMongoCrypt::Binary, bytes_written : UInt32*, status : LibMongoCrypt::Status) : Bool {
    Mongo::ClientEncryption::CryptoHooks.aes("aes-256-cbc", true, key, iv, input, output, bytes_written, status)
  }

  CBC_DECRYPT = ->(_ctx : Void*, key : LibMongoCrypt::Binary, iv : LibMongoCrypt::Binary, input : LibMongoCrypt::Binary, output : LibMongoCrypt::Binary, bytes_written : UInt32*, status : LibMongoCrypt::Status) : Bool {
    Mongo::ClientEncryption::CryptoHooks.aes("aes-256-cbc", false, key, iv, input, output, bytes_written, status)
  }

  CTR_ENCRYPT = ->(_ctx : Void*, key : LibMongoCrypt::Binary, iv : LibMongoCrypt::Binary, input : LibMongoCrypt::Binary, output : LibMongoCrypt::Binary, bytes_written : UInt32*, status : LibMongoCrypt::Status) : Bool {
    Mongo::ClientEncryption::CryptoHooks.aes("aes-256-ctr", true, key, iv, input, output, bytes_written, status)
  }

  CTR_DECRYPT = ->(_ctx : Void*, key : LibMongoCrypt::Binary, iv : LibMongoCrypt::Binary, input : LibMongoCrypt::Binary, output : LibMongoCrypt::Binary, bytes_written : UInt32*, status : LibMongoCrypt::Status) : Bool {
    Mongo::ClientEncryption::CryptoHooks.aes("aes-256-ctr", false, key, iv, input, output, bytes_written, status)
  }

  HMAC_SHA256 = ->(_ctx : Void*, key : LibMongoCrypt::Binary, input : LibMongoCrypt::Binary, output : LibMongoCrypt::Binary, status : LibMongoCrypt::Status) : Bool {
    Mongo::ClientEncryption::CryptoHooks.hmac(LibCrypto.evp_sha256, key, input, output, status)
  }

  HMAC_SHA512 = ->(_ctx : Void*, key : LibMongoCrypt::Binary, input : LibMongoCrypt::Binary, output : LibMongoCrypt::Binary, status : LibMongoCrypt::Status) : Bool {
    Mongo::ClientEncryption::CryptoHooks.hmac(LibCrypto.evp_sha512, key, input, output, status)
  }

  SHA256 = ->(_ctx : Void*, input : LibMongoCrypt::Binary, output : LibMongoCrypt::Binary, status : LibMongoCrypt::Status) : Bool {
    Mongo::ClientEncryption::CryptoHooks.sha256(input, output, status)
  }

  RANDOM = ->(_ctx : Void*, output : LibMongoCrypt::Binary, count : UInt32, status : LibMongoCrypt::Status) : Bool {
    Mongo::ClientEncryption::CryptoHooks.random(output, count, status)
  }

  def install(crypt : LibMongoCrypt::Crypt) : Nil
    unless LibMongoCrypt.setopt_crypto_hooks(
             crypt,
             CBC_ENCRYPT,
             CBC_DECRYPT,
             RANDOM,
             HMAC_SHA512,
             HMAC_SHA256,
             SHA256,
             Pointer(Void).null
           )
      CBinary.raise_crypt(crypt)
    end
    unless LibMongoCrypt.setopt_aes_256_ctr(crypt, CTR_ENCRYPT, CTR_DECRYPT, Pointer(Void).null)
      CBinary.raise_crypt(crypt)
    end
  end

  def aes(name : String, encrypt : Bool, key : LibMongoCrypt::Binary, iv : LibMongoCrypt::Binary, input : LibMongoCrypt::Binary, output : LibMongoCrypt::Binary, bytes_written : UInt32*, status : LibMongoCrypt::Status) : Bool
    key_ptr, _key_len = view(key)
    iv_ptr, _iv_len = view(iv)
    in_ptr, in_len = view(input)
    out_ptr, out_len = view(output)
    if key_ptr.null? || iv_ptr.null? || in_ptr.null? || out_ptr.null? || bytes_written.null?
      return fail(status, "AES hook got a null buffer.")
    end
    if in_len > Int32::MAX || out_len < in_len
      return fail(status, "AES hook buffer size is invalid.")
    end

    cipher = LibCrypto.evp_get_cipherbyname(name)
    if cipher.null?
      return fail(status, "unknown cipher #{name}")
    end

    ctx = LibCrypto.evp_cipher_ctx_new
    if ctx.null?
      return fail(status, "EVP_CIPHER_CTX_new failed.")
    end
    begin
      enc = encrypt ? 1 : 0
      if LibCrypto.evp_cipherinit_ex(ctx, cipher, Pointer(Void).null, key_ptr, iv_ptr, enc) != 1
        return fail(status, "EVP_CipherInit_ex failed.")
      end
      LibCrypto.evp_cipher_ctx_set_padding(ctx, 0)
      update_len = 0
      if LibCrypto.evp_cipherupdate(ctx, out_ptr, pointerof(update_len), in_ptr, in_len.to_i32) != 1
        return fail(status, "EVP_CipherUpdate failed.")
      end
      final_len = 0
      if LibCrypto.evp_cipherfinal_ex(ctx, out_ptr + update_len, pointerof(final_len)) != 1
        return fail(status, "EVP_CipherFinal_ex failed.")
      end
      written = update_len + final_len
      if written < 0 || written.to_u32 > out_len
        return fail(status, "AES hook wrote past the output buffer.")
      end
      bytes_written.value = written.to_u32
      true
    ensure
      LibCrypto.evp_cipher_ctx_free(ctx)
    end
  end

  def hmac(digest : LibCrypto::EVP_MD, key : LibMongoCrypt::Binary, input : LibMongoCrypt::Binary, output : LibMongoCrypt::Binary, status : LibMongoCrypt::Status) : Bool
    key_ptr, key_len = view(key)
    in_ptr, in_len = view(input)
    out_ptr, out_len = view(output)
    if key_ptr.null? || in_ptr.null? || out_ptr.null? || digest.null?
      return fail(status, "HMAC hook got a null buffer.")
    end
    md_len = 0_u32
    ptr = LibCrypto.hmac(
      digest,
      key_ptr.as(LibCrypto::Char*),
      key_len.to_i32,
      in_ptr.as(LibCrypto::Char*),
      LibCrypto::SizeT.new(in_len),
      out_ptr.as(LibCrypto::Char*),
      pointerof(md_len)
    )
    if ptr.null? || md_len == 0 || md_len > out_len
      return fail(status, "HMAC failed.")
    end
    true
  end

  def sha256(input : LibMongoCrypt::Binary, output : LibMongoCrypt::Binary, status : LibMongoCrypt::Status) : Bool
    in_ptr, in_len = view(input)
    out_ptr, out_len = view(output)
    if in_ptr.null? || out_ptr.null?
      return fail(status, "SHA-256 hook got a null buffer.")
    end
    size = 0_u32
    if LibCrypto.evp_digest(in_ptr.as(Void*), LibCrypto::SizeT.new(in_len), out_ptr, pointerof(size), LibCrypto.evp_sha256, Pointer(Void).null) != 1
      return fail(status, "SHA-256 failed.")
    end
    if size == 0 || size > out_len
      return fail(status, "SHA-256 output is invalid.")
    end
    true
  end

  def random(output : LibMongoCrypt::Binary, count : UInt32, status : LibMongoCrypt::Status) : Bool
    out_ptr, out_len = view(output)
    if out_ptr.null? || count > out_len || count > Int32::MAX
      return fail(status, "random hook buffer size is invalid.")
    end
    if LibCrypto.rand_bytes(out_ptr.as(LibCrypto::Char*), count.to_i32) != 1
      return fail(status, "RAND_bytes failed.")
    end
    true
  end

  private def view(bin : LibMongoCrypt::Binary) : {UInt8*, UInt32}
    if bin.null?
      return {Pointer(UInt8).null, 0_u32}
    end
    {LibMongoCrypt.binary_data(bin), LibMongoCrypt.binary_len(bin)}
  end

  private def fail(status : LibMongoCrypt::Status, message : String) : Bool
    unless status.null?
      LibMongoCrypt.status_set(status, LibMongoCrypt::StatusType::ErrorClient, 1_u32, message, -1)
    end
    false
  end
end
