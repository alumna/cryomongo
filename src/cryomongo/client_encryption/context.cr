# Drive a mongocrypt_ctx_t until READY and copy the finalize BSON.
# Explicit encrypt / decrypt / data-key use NEED_MONGO_KEYS and READY.
# Auto-encryption states and cloud KMS are not implemented here.
# :nodoc:
module Mongo::ClientEncryption::Context
  extend self

  def run(ctx : LibMongoCrypt::Ctx, key_vault : Mongo::Collection) : BSON
    loop do
      state = LibMongoCrypt.ctx_state(ctx)
      case state
      when .error?
        CBinary.raise_ctx(ctx)
      when .need_mongo_keys?
        feed_mongo_keys(ctx, key_vault)
      when .ready?
        return finalize_owned(ctx)
      when .done?
        raise Mongo::Error::Crypt.new("libmongocrypt finished with no result.")
      when .need_kms?, .need_kms_credentials?
        raise Mongo::Error::Crypt.new("KMS HTTP is not implemented. Use local KMS.")
      when .need_mongo_collinfo?, .need_mongo_collinfo_with_db?, .need_mongo_markings?
        raise Mongo::Error::Crypt.new("Auto-encryption is not implemented. Use ClientEncryption.encrypt and decrypt.")
      else
        raise Mongo::Error::Crypt.new("Unexpected libmongocrypt state #{state}.")
      end
    end
  end

  # NEED_MONGO_KEYS: mongo_op is a find filter on the key vault (C header).
  # libmongocrypt copies each fed document. Do not call mongo_feed when find
  # returns nothing. Always call mongo_done.
  private def feed_mongo_keys(ctx : LibMongoCrypt::Ctx, key_vault : Mongo::Collection) : Nil
    op = CBinary.copy_out do |bin|
      CBinary.raise_ctx(ctx) unless LibMongoCrypt.ctx_mongo_op(ctx, bin)
    end
    filter = BSON.new(op)
    key_vault.find(filter).each do |doc|
      CBinary.with_bytes(doc.data) do |bin|
        CBinary.raise_ctx(ctx) unless LibMongoCrypt.ctx_mongo_feed(ctx, bin)
      end
    end
    CBinary.raise_ctx(ctx) unless LibMongoCrypt.ctx_mongo_done(ctx)
  end

  # Finalize output is a view on the ctx. Clone before the caller destroys it.
  private def finalize_owned(ctx : LibMongoCrypt::Ctx) : BSON
    bytes = CBinary.copy_out do |bin|
      CBinary.raise_ctx(ctx) unless LibMongoCrypt.ctx_finalize(ctx, bin)
    end
    BSON.new(bytes)
  end
end
