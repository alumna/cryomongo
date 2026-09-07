# Drive a mongocrypt_ctx_t until READY and copy the finalize BSON.
# Explicit encrypt / decrypt / data-key use NEED_MONGO_KEYS and READY.
# Auto-encryption also handles NEED_MONGO_COLLINFO. Cloud KMS is not implemented.
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

  # Rewrap may finish DONE with no keys. Empty BSON means no bulk write.
  def run_rewrap(ctx : LibMongoCrypt::Ctx, key_vault : Mongo::Collection) : BSON
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
        return BSON.new
      when .need_kms?, .need_kms_credentials?
        raise Mongo::Error::Crypt.new("KMS HTTP is not implemented. Use local KMS.")
      when .need_mongo_collinfo?, .need_mongo_collinfo_with_db?, .need_mongo_markings?
        raise Mongo::Error::Crypt.new("Rewrap does not use auto-encryption states.")
      else
        raise Mongo::Error::Crypt.new("Unexpected libmongocrypt state #{state}.")
      end
    end
  end

  # Auto encrypt / decrypt. *metadata_client* runs listCollections (bypass on the parent).
  def run_auto(ctx : LibMongoCrypt::Ctx, key_vault : Mongo::Collection, metadata_client : Mongo::Client, database : String) : BSON
    loop do
      state = LibMongoCrypt.ctx_state(ctx)
      case state
      when .error?
        CBinary.raise_ctx(ctx)
      when .need_mongo_keys?
        feed_mongo_keys(ctx, key_vault)
      when .need_mongo_collinfo?
        feed_mongo_collinfo(ctx, metadata_client, database)
      when .need_mongo_collinfo_with_db?
        feed_mongo_collinfo_with_db(ctx, metadata_client)
      when .need_mongo_markings?
        raise Mongo::Error::Crypt.new("crypt_shared did not analyze the command. mongocryptd is not implemented. Set extraOptions.cryptSharedLibPath or CRYPT_SHARED_LIB_PATH.")
      when .ready?
        return finalize_owned(ctx)
      when .done?
        raise Mongo::Error::Crypt.new("libmongocrypt finished with no result.")
      when .need_kms?, .need_kms_credentials?
        raise Mongo::Error::Crypt.new("KMS HTTP is not implemented. Use local KMS.")
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

  # NEED_MONGO_COLLINFO: mongo_op is a listCollections filter. Feed every result.
  # Clone each info document so the cursor can move.
  private def feed_mongo_collinfo(ctx : LibMongoCrypt::Ctx, metadata_client : Mongo::Client, database : String) : Nil
    op = CBinary.copy_out do |bin|
      CBinary.raise_ctx(ctx) unless LibMongoCrypt.ctx_mongo_op(ctx, bin)
    end
    filter = BSON.new(op)
    feed_list_collections(ctx, metadata_client, database, filter)
  end

  # NEED_MONGO_COLLINFO_WITH_DB: filter from mongo_op, database from mongo_db.
  # bulkWrite is sent to admin; the op namespace may be another database.
  private def feed_mongo_collinfo_with_db(ctx : LibMongoCrypt::Ctx, metadata_client : Mongo::Client) : Nil
    op = CBinary.copy_out do |bin|
      CBinary.raise_ctx(ctx) unless LibMongoCrypt.ctx_mongo_op(ctx, bin)
    end
    filter = BSON.new(op)
    ptr = LibMongoCrypt.ctx_mongo_db(ctx)
    if ptr.null?
      CBinary.raise_ctx(ctx)
    end
    db = String.new(ptr)
    feed_list_collections(ctx, metadata_client, db, filter)
  end

  private def feed_list_collections(ctx : LibMongoCrypt::Ctx, metadata_client : Mongo::Client, database : String, filter : BSON) : Nil
    metadata_client[database].list_collections(filter: filter).each do |info|
      owned = BSON.new(info.data)
      CBinary.with_bytes(owned.data) do |bin|
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
