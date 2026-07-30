class Mongo::Bulk
  # The base Struct inherited by all the bulk write models.
  abstract struct WriteModel
    def <=>(other)
      self.class.to_s <=> other.class.to_s
    end
  end

  # Insert one document.
  struct InsertOne < WriteModel
    getter document : BSON

    def initialize(document)
      @document = BSON.new(document)
    end
  end

  # Delete one document.
  struct DeleteOne < WriteModel
    getter filter : BSON
    getter collation : Collation?
    getter hint : (String | BSON)?

    def initialize(filter, @collation = nil, @hint = nil)
      @filter = BSON.new(filter)
    end
  end

  # Delete one or more documents.
  struct DeleteMany < WriteModel
    getter filter : BSON
    getter collation : Collation?
    getter hint : (String | BSON)?

    def initialize(filter, @collation = nil, @hint = nil)
      @filter = BSON.new(filter)
    end
  end

  # Replace one document.
  struct ReplaceOne < WriteModel
    getter filter : BSON
    getter replacement : BSON
    getter collation : Collation?
    getter hint : (String | BSON)?
    getter upsert : Bool?

    def initialize(filter, replacement, @collation = nil, @hint = nil, @upsert = nil)
      @filter = BSON.new(filter)
      @replacement = BSON.new(replacement)
    end
  end

  # Update one document.
  struct UpdateOne < WriteModel
    getter filter : BSON
    getter update : BSON | Array(BSON)
    getter array_filters : Array(BSON)?
    getter collation : Collation?
    getter hint : (String | BSON)?
    getter upsert : Bool?

    def initialize(filter, update, @array_filters = nil, @collation = nil, @hint = nil, @upsert = nil)
      @filter = BSON.new(filter)
      @update = update
    end
  end

  # Update one or more documents.
  struct UpdateMany < WriteModel
    getter filter : BSON
    getter update : BSON | Array(BSON)
    getter array_filters : Array(BSON)?
    getter collation : Collation?
    getter hint : (String | BSON)?
    getter upsert : Bool?

    def initialize(filter, update, @array_filters = nil, @collation = nil, @hint = nil, @upsert = nil)
      @filter = BSON.new(filter)
      @update = update
    end
  end
end
