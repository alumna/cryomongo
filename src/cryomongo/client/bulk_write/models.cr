# Write models for `Mongo::Client#bulk_write` (MongoDB 8.0 client `bulkWrite`).
# Distinct from collection `Mongo::Bulk` models: each model has a namespace.
module Mongo::ClientBulk
  alias WriteModel = InsertOne | UpdateOne | UpdateMany | ReplaceOne | DeleteOne | DeleteMany

  # Insert one document into *namespace* (`db.collection`).
  struct InsertOne
    getter namespace : String
    getter document : BSON
    getter inserted_id : BSON::Value

    def initialize(@namespace : String, document)
      @document, @inserted_id = ClientBulk.with_inserted_id(document)
    end
  end

  # Update one document in *namespace*.
  struct UpdateOne
    getter namespace : String
    getter filter : BSON
    getter update : BSON | Array(BSON)
    getter upsert : Bool?
    getter collation : Collation?
    getter hint : (String | BSON)?
    getter array_filters : Array(BSON)?
    getter sort : BSON?

    def initialize(
      @namespace : String,
      filter,
      update,
      @upsert : Bool? = nil,
      @collation : Collation? = nil,
      @hint : (String | BSON)? = nil,
      @array_filters : Array(BSON)? = nil,
      sort = nil,
    )
      @filter = BSON.new(filter)
      @sort = sort.try { |s| BSON.new(s) }
      @update = ClientBulk.validate_update(update)
    end
  end

  # Update many documents in *namespace*.
  struct UpdateMany
    getter namespace : String
    getter filter : BSON
    getter update : BSON | Array(BSON)
    getter upsert : Bool?
    getter collation : Collation?
    getter hint : (String | BSON)?
    getter array_filters : Array(BSON)?

    def initialize(
      @namespace : String,
      filter,
      update,
      @upsert : Bool? = nil,
      @collation : Collation? = nil,
      @hint : (String | BSON)? = nil,
      @array_filters : Array(BSON)? = nil,
    )
      @filter = BSON.new(filter)
      @update = ClientBulk.validate_update(update)
    end
  end

  # Replace one document in *namespace*.
  struct ReplaceOne
    getter namespace : String
    getter filter : BSON
    getter replacement : BSON
    getter upsert : Bool?
    getter collation : Collation?
    getter hint : (String | BSON)?
    getter sort : BSON?

    def initialize(
      @namespace : String,
      filter,
      replacement,
      @upsert : Bool? = nil,
      @collation : Collation? = nil,
      @hint : (String | BSON)? = nil,
      sort = nil,
    )
      @filter = BSON.new(filter)
      @sort = sort.try { |s| BSON.new(s) }
      @replacement = Collection.validate_replacement!(replacement)
    end
  end

  # Delete one document from *namespace*.
  struct DeleteOne
    getter namespace : String
    getter filter : BSON
    getter collation : Collation?
    getter hint : (String | BSON)?

    def initialize(
      @namespace : String,
      filter,
      @collation : Collation? = nil,
      @hint : (String | BSON)? = nil,
    )
      @filter = BSON.new(filter)
    end
  end

  # Delete many documents from *namespace*.
  struct DeleteMany
    getter namespace : String
    getter filter : BSON
    getter collation : Collation?
    getter hint : (String | BSON)?

    def initialize(
      @namespace : String,
      filter,
      @collation : Collation? = nil,
      @hint : (String | BSON)? = nil,
    )
      @filter = BSON.new(filter)
    end
  end

  # If `_id` is missing, generate one and put it first. If `_id` is present, leave the document as-is.
  def self.with_inserted_id(document) : {BSON, BSON::Value}
    doc = Commands::Insert.with_ids([document])[0]
    {doc, doc["_id"]}
  end

  # Empty update documents are a client error. Pipelines are not validated.
  def self.validate_update(update) : BSON | Array(BSON)
    if update.is_a?(Array)
      update.map { |u| BSON.new(u) }
    else
      bson = BSON.new(update)
      first = bson.each.next
      if first.is_a?(Iterator::Stop)
        raise Error::Client.new("The update document parameter must have only atomic modifiers")
      end
      Collection.validate_update!(bson)
      bson
    end
  end

  # Build one `ops` document. *ns_index* is the index in that batch's `nsInfo`.
  def self.op_document(model : WriteModel, ns_index : Int32) : BSON
    case model
    when InsertOne
      BSON.build do |builder|
        builder["insert"] = ns_index
        builder["document"] = model.document
      end
    when UpdateOne
      update_op(ns_index, model.filter, model.update, false, model.upsert, model.collation, model.hint, model.array_filters, model.sort)
    when UpdateMany
      update_op(ns_index, model.filter, model.update, true, model.upsert, model.collation, model.hint, model.array_filters, nil)
    when ReplaceOne
      update_op(ns_index, model.filter, model.replacement, false, model.upsert, model.collation, model.hint, nil, model.sort)
    when DeleteOne
      delete_op(ns_index, model.filter, false, model.collation, model.hint)
    when DeleteMany
      delete_op(ns_index, model.filter, true, model.collation, model.hint)
    else
      raise Error::Client.new("unsupported client bulkWrite model")
    end
  end

  private def self.update_op(
    ns_index : Int32,
    filter : BSON,
    update_mods : BSON | Array(BSON),
    multi : Bool,
    upsert : Bool?,
    collation : Collation?,
    hint : (String | BSON)?,
    array_filters : Array(BSON)?,
    sort : BSON?,
  ) : BSON
    BSON.build do |builder|
      builder["update"] = ns_index
      builder["filter"] = filter
      builder["updateMods"] = update_mods
      builder["multi"] = multi
      builder["upsert"] = upsert unless upsert.nil?
      builder["collation"] = collation if collation
      builder["hint"] = hint if hint
      builder["arrayFilters"] = array_filters if array_filters
      builder["sort"] = sort if sort
    end
  end

  private def self.delete_op(
    ns_index : Int32,
    filter : BSON,
    multi : Bool,
    collation : Collation?,
    hint : (String | BSON)?,
  ) : BSON
    BSON.build do |builder|
      builder["delete"] = ns_index
      builder["filter"] = filter
      builder["multi"] = multi
      builder["collation"] = collation if collation
      builder["hint"] = hint if hint
    end
  end
end
