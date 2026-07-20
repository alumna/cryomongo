class Mongo::Collection
  # Executes multiple write operations.
  #
  # An error will be raised if the *requests* parameter is empty.
  #
  # NOTE: [for more details, please check the official specifications document](https://github.com/mongodb/specifications/blob/master/source/driver-bulk-update.rst).
  def bulk_write(requests : Array(Bulk::WriteModel), *, ordered : Bool, bypass_document_validation : Bool? = nil, session : Session::ClientSession? = nil) : Bulk::WriteResult
    raise Mongo::Bulk::Error.new "Tried to execute an empty bulk" unless requests.size > 0
    bulk = Mongo::Bulk.new(self, ordered, requests, session: session)
    bulk.execute(bypass_document_validation: bypass_document_validation)
  end

  # Create a `Mongo::Bulk` instance.
  def bulk(ordered : Bool = true, session : Session::ClientSession? = nil)
    Mongo::Bulk.new(self, ordered, session: session)
  end

  # Inserts the provided document. If the document is missing an identifier, it will be generated.
  #
  # NOTE: [for more details, please check the official documentation](https://docs.mongodb.com/manual/reference/command/insert/).
  def insert_one(document, *, write_concern : WriteConcern? = nil, bypass_document_validation : Bool? = nil, session : Session::ClientSession? = nil) : Commands::Common::InsertResult?
    self.command(Commands::Insert, documents: [document], session: session, options: {
      write_concern:              write_concern,
      bypass_document_validation: bypass_document_validation,
      ordered:                    true,
    })
  end

  # Inserts the provided document. If any documents are missing an identifier, they will be generated.
  #
  # NOTE: [for more details, please check the official documentation](https://docs.mongodb.com/manual/reference/command/insert/).
  def insert_many(
    documents : Array,
    *,
    ordered : Bool? = nil,
    write_concern : WriteConcern? = nil,
    bypass_document_validation : Bool? = nil,
    session : Session::ClientSession? = nil,
  ) : Commands::Common::InsertResult?
    raise Mongo::Error.new "Tried to insert an empty document array" unless documents.size > 0
    self.command(Commands::Insert, documents: documents, session: session, options: {
      ordered:                    ordered,
      write_concern:              write_concern,
      bypass_document_validation: bypass_document_validation,
    })
  end

  # Deletes one document.
  #
  # NOTE: [for more details, please check the official documentation](https://docs.mongodb.com/manual/reference/command/delete/).
  def delete_one(
    filter,
    *,
    collation : Collation? = nil,
    hint : (String | H)? = nil,
    ordered : Bool? = nil,
    write_concern : WriteConcern? = nil,
    session : Session::ClientSession? = nil,
  ) : Commands::Common::DeleteResult? forall H
    delete = Tools.merge_bson({
      q:     BSON.new(filter),
      limit: 1,
    }, {
      collation: collation,
      hint:      hint,
    })
    self.command(Commands::Delete, deletes: [delete], session: session, options: {
      ordered:       ordered,
      write_concern: write_concern,
    })
  end

  # Deletes multiple documents.
  #
  # NOTE: [for more details, please check the official documentation](https://docs.mongodb.com/manual/reference/command/delete/).
  def delete_many(
    filter,
    *,
    collation : Collation? = nil,
    hint : (String | H)? = nil,
    ordered : Bool? = nil,
    write_concern : WriteConcern? = nil,
    session : Session::ClientSession? = nil,
  ) : Commands::Common::DeleteResult? forall H
    delete = Tools.merge_bson({
      q:     BSON.new(filter),
      limit: 0,
    }, {
      collation: collation,
      hint:      hint,
    })
    self.command(Commands::Delete, deletes: [delete], session: session, options: {
      ordered:       ordered,
      write_concern: write_concern,
    })
  end

  protected def self.validate_replacement!(replacement)
    replacement = BSON.new(replacement)
    first_element = replacement.each.next
    raise Mongo::Error.new "The replacement document must not be an array" if replacement.is_a? Array
    unless first_element.is_a? Iterator::Stop
      if first_element[0].starts_with? '$'
        raise Mongo::Error.new "The replacement document parameter must not begin with an atomic modifier"
      elsif first_element[0] == '0'
        raise Mongo::Error.new "The replacement document must not be an array"
      end
    end
    replacement
  end

  protected def self.validate_update!(update)
    unless update.is_a? Array
      update = BSON.new(update)
      first_element = update.each.next
      unless first_element.is_a? Iterator::Stop
        unless first_element[0].starts_with? '$'
          raise Mongo::Error.new "The update document parameter must have only atomic modifiers"
        end
      end
    end
    update
  end

  # Replaces a single document.
  #
  # NOTE: [for more details, please check the official documentation](https://docs.mongodb.com/manual/reference/command/update/).
  def replace_one(
    filter,
    replacement,
    *,
    upsert : Bool = false,
    collation : Collation? = nil,
    hint : (String | H)? = nil,
    ordered : Bool? = nil,
    write_concern : WriteConcern? = nil,
    bypass_document_validation : Bool? = nil,
    session : Session::ClientSession? = nil,
  ) : Commands::Common::UpdateResult? forall H
    updates = [
      Tools.merge_bson({
        q:      BSON.new(filter),
        u:      self.class.validate_replacement!(replacement),
        multi:  false,
        upsert: upsert,
      }, {
        collation: collation,
        hint:      hint,
      }),
    ]
    self.command(Commands::Update, updates: updates, session: session, options: {
      ordered:                    ordered,
      write_concern:              write_concern,
      bypass_document_validation: bypass_document_validation,
    })
  end

  # Updates one document.
  #
  # NOTE: [for more details, please check the official documentation](https://docs.mongodb.com/manual/reference/command/update/).
  def update_one(
    filter,
    update,
    *,
    upsert : Bool = false,
    array_filters = nil,
    collation : Collation? = nil,
    hint : (String | H)? = nil,
    ordered : Bool? = nil,
    write_concern : WriteConcern? = nil,
    bypass_document_validation : Bool? = nil,
    session : Session::ClientSession? = nil,
  ) : Commands::Common::UpdateResult? forall H
    updates = [
      Tools.merge_bson({
        q:      BSON.new(filter),
        u:      self.class.validate_update!(update),
        multi:  false,
        upsert: upsert,
      }, {
        array_filters: array_filters,
        collation:     collation,
        hint:          hint,
      }),
    ]
    self.command(Commands::Update, updates: updates, session: session, options: {
      ordered:                    ordered,
      write_concern:              write_concern,
      bypass_document_validation: bypass_document_validation,
    })
  end

  # Updates multiple documents.
  #
  # NOTE: [for more details, please check the official documentation](https://docs.mongodb.com/manual/reference/command/update/).
  def update_many(
    filter,
    update,
    *,
    upsert : Bool = false,
    array_filters = nil,
    collation : Collation? = nil,
    hint : (String | H)? = nil,
    ordered : Bool? = nil,
    write_concern : WriteConcern? = nil,
    bypass_document_validation : Bool? = nil,
    session : Session::ClientSession? = nil,
  ) : Commands::Common::UpdateResult? forall H
    updates = [
      Tools.merge_bson({
        q:      BSON.new(filter),
        u:      self.class.validate_update!(update),
        multi:  true,
        upsert: upsert,
      }, {
        array_filters: array_filters,
        collation:     collation,
        hint:          hint,
      }),
    ]
    self.command(Commands::Update, updates: updates, session: session, options: {
      ordered:                    ordered,
      write_concern:              write_concern,
      bypass_document_validation: bypass_document_validation,
    })
  end
end
