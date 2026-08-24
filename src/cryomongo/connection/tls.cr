require "openssl"

# TLS context for a MongoDB socket. Crystal's OpenSSL wrapper has no password
# argument on private_key=. OpenSSL 3 PKCS#8 also ignores
# SSL_CTX_set_default_passwd_cb on SSL_CTX_use_PrivateKey_file, so encrypted
# keys are loaded with PEM_read_bio_PrivateKey. OCSP stapling follows URI flags.
module Mongo::TLS
  extend self

  SSL_CTRL_SET_TLSEXT_STATUS_REQ_TYPE = 65
  TLSEXT_STATUSTYPE_OCSP              =  1

  # OpenSSL pem_password_cb. String is a Reference, so Box.box is the String
  # pointer itself. Keep that String alive across the C call.
  PASSWD_CB = ->(buf : LibC::Char*, size : LibC::Int, rwflag : LibC::Int, userdata : Void*) : LibC::Int {
    password_cb(buf, size, rwflag, userdata)
  }

  # Fill *buf* with the PEM password stored as callback userdata.
  def password_cb(buf : LibC::Char*, size : LibC::Int, _rwflag : LibC::Int, userdata : Void*) : LibC::Int
    return 0 if userdata.null? || size <= 0
    password = Box(String).unbox(userdata)
    n = password.bytesize
    n = size - 1 if n >= size
    dst = Slice(UInt8).new(buf.as(UInt8*), size)
    password.to_slice[0, n].copy_to(dst[0, n])
    dst[n] = 0 if n < size
    n
  end

  def configure(context : OpenSSL::SSL::Context::Client, options : Mongo::Options) : Nil
    handle = context.to_unsafe
    if tls_ca_file = options.tls_ca_file
      context.ca_certificates = tls_ca_file
    end

    if tls_certificate_key_file = options.tls_certificate_key_file
      context.certificate_chain = tls_certificate_key_file
      if password = options.tls_certificate_key_file_password
        load_encrypted_key(handle, tls_certificate_key_file, password)
      else
        context.private_key = tls_certificate_key_file
      end
    end

    if options.tls_insecure || options.tls_allow_invalid_certificates
      context.verify_mode = OpenSSL::SSL::VerifyMode::NONE
    end

    # Request stapled OCSP unless the URI turns revocation checks off.
    # This driver does not fetch OCSP HTTP responders, so
    # tlsDisableOCSPEndpointCheck is already the default.
    skip_ocsp = options.tls_disable_certificate_revocation_check ||
                options.tls_insecure ||
                options.tls_allow_invalid_certificates
    unless skip_ocsp
      LibSSL.ssl_ctx_ctrl(
        handle,
        SSL_CTRL_SET_TLSEXT_STATUS_REQ_TYPE,
        TLSEXT_STATUSTYPE_OCSP.to_u64,
        Pointer(Void).null
      )
    end
  end

  private def load_encrypted_key(handle : LibSSL::SSLContext, path : String, password : String) : Nil
    userdata = Box.box(password)
    bio = LibCrypto.bio_new_file(path, "r")
    raise OpenSSL::Error.new("BIO_new_file") if bio.null?
    pkey = Pointer(Void).null
    begin
      pkey = LibCrypto.pem_read_bio_privatekey(bio, Pointer(Void*).null, PASSWD_CB, userdata)
    ensure
      LibCrypto.BIO_free(bio)
    end
    raise OpenSSL::Error.new("PEM_read_bio_PrivateKey") if pkey.null?
    begin
      ret = LibSSL.ssl_ctx_use_privatekey(handle, pkey)
      raise OpenSSL::Error.new("SSL_CTX_use_PrivateKey") unless ret == 1
    ensure
      LibCrypto.evp_pkey_free(pkey)
    end
  end
end

lib LibCrypto
  fun bio_new_file = BIO_new_file(filename : UInt8*, mode : UInt8*) : Bio*
  fun pem_read_bio_privatekey = PEM_read_bio_PrivateKey(bp : Bio*, x : Void**, cb : (LibC::Char*, LibC::Int, LibC::Int, Void*) -> LibC::Int, u : Void*) : Void*
  fun evp_pkey_free = EVP_PKEY_free(pkey : Void*)
end

lib LibSSL
  fun ssl_ctx_use_privatekey = SSL_CTX_use_PrivateKey(ctx : SSLContext, pkey : Void*) : Int
end
