class Mongo::Collection
  private def check_find_and_modify_result!(result)
    return nil if result.nil?

    if last_error_object = result["last_error_object"]?
      last_error_object = last_error_object.as(BSON)
      code = last_error_object["code"]?
      code_name = last_error_object["codeName"]?.try &.as(String)
      msg = last_error_object["errmsg"]?.try &.as(String)
      labels = last_error_object["errorLabels"]?.try { |l|
        Array(String).from_bson(l)
      } || [] of String
      details = last_error_object["errInfo"]?.try &.as(BSON)
      raise Mongo::Error::Command.new(code, code_name, msg, details, error_labels: Set(String).new(labels))
    end

    result["value"]?.try &.as(BSON)
  end

  # Finds a single document and deletes it, returning the original. The document to return may be nil.
  #
  # NOTE: [for more details, please check the official documentation](https://docs.mongodb.com/manual/reference/command/findAndModify/).
  def find_one_and_delete(
    filter,
    *,
    sort = nil,
    fields = nil,
    bypass_document_validation : Bool? = nil,
    write_concern : WriteConcern? = nil,
    collation : Collation? = nil,
    hint : (String | H)? = nil,
    max_time_ms : Int64? = nil,
    session : Session::ClientSession? = nil,
  ) : BSON? forall H
    result = self.command(Commands::FindAndModify, filter: filter, session: session, options: {
      remove:                     true,
      sort:                       sort.try { BSON.new(sort) },
      fields:                     fields.try { BSON.new(fields) },
      bypass_document_validation: bypass_document_validation,
      write_concern:              write_concern,
      collation:                  collation,
      hint:                       hint,
      max_time_ms:                max_time_ms,
    })
    check_find_and_modify_result!(result)
  end

  # Finds a single document and replaces it, returning either the original or the replaced
  # document. The document to return may be nil.
  #
  # NOTE: [for more details, please check the official documentation](https://docs.mongodb.com/manual/reference/command/findAndModify/).
  def find_one_and_replace(
    filter,
    replacement,
    *,
    sort = nil,
    new : Bool? = nil,
    fields = nil,
    upsert : Bool? = nil,
    bypass_document_validation : Bool? = nil,
    write_concern : WriteConcern? = nil,
    collation : Collation? = nil,
    array_filters = nil,
    hint : (String | H)? = nil,
    max_time_ms : Int64? = nil,
    session : Session::ClientSession? = nil,
  ) : BSON? forall H
    replacement = self.class.validate_replacement!(replacement)
    result = self.command(Commands::FindAndModify, filter: filter, session: session, options: {
      update:                     replacement,
      sort:                       sort.try { BSON.new(sort) },
      new:                        new,
      fields:                     fields.try { BSON.new(fields) },
      upsert:                     upsert,
      bypass_document_validation: bypass_document_validation,
      write_concern:              write_concern,
      collation:                  collation,
      array_filters:              array_filters,
      hint:                       hint,
      max_time_ms:                max_time_ms,
    })
    check_find_and_modify_result!(result)
  end

  # Finds a single document and updates it, returning either the original or the updated
  # document. The document to return may be nil.
  #
  # NOTE: [for more details, please check the official documentation](https://docs.mongodb.com/manual/reference/command/findAndModify/).
  def find_one_and_update(
    filter,
    update,
    *,
    sort = nil,
    new : Bool? = nil,
    fields = nil,
    upsert : Bool? = nil,
    bypass_document_validation : Bool? = nil,
    write_concern : WriteConcern? = nil,
    collation : Collation? = nil,
    array_filters = nil,
    hint : (String | H)? = nil,
    max_time_ms : Int64? = nil,
    session : Session::ClientSession? = nil,
  ) : BSON? forall H
    update = self.class.validate_update!(update)
    result = self.command(Commands::FindAndModify, filter: filter, session: session, options: {
      update:                     update,
      sort:                       sort.try { BSON.new(sort) },
      new:                        new,
      fields:                     fields.try { BSON.new(fields) },
      upsert:                     upsert,
      bypass_document_validation: bypass_document_validation,
      write_concern:              write_concern,
      collation:                  collation,
      array_filters:              array_filters,
      hint:                       hint,
      max_time_ms:                max_time_ms,
    })
    check_find_and_modify_result!(result)
  end
end
