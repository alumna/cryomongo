class Mongo::Collection
  # Runs an aggregation framework pipeline.
  #
  # NOTE: [for more details, please check the official MongoDB documentation](https://docs.mongodb.com/manual/reference/command/aggregate/).
  def aggregate(
    pipeline : Array,
    *,
    allow_disk_use : Bool? = nil,
    batch_size : Int32? = nil,
    max_time_ms : Int64? = nil,
    bypass_document_validation : Bool? = nil,
    collation : Collation? = nil,
    hint : (String | H)? = nil,
    comment : String? = nil,
    read_concern : ReadConcern? = nil,
    write_concern : WriteConcern? = nil,
    read_preference : ReadPreference? = nil,
    session : Session::ClientSession? = nil,
  ) : Mongo::Cursor? forall H
    self.command(Commands::Aggregate, pipeline: pipeline, session: session, options: {
      allow_disk_use:             allow_disk_use,
      cursor:                     batch_size.try { {batchSize: batch_size} },
      bypass_document_validation: bypass_document_validation,
      collation:                  collation,
      hint:                       hint.is_a?(String) ? hint : BSON.new(hint),
      comment:                    comment,
      max_time_ms:                max_time_ms,
      read_concern:               read_concern,
      write_concern:              write_concern,
      read_preference:            read_preference,
    }) { |result|
      Cursor.new(@database.client, result, batch_size: batch_size, session: session)
    }
  end

  # Count the number of documents in a collection that match the given filter.
  # Note that an empty filter will force a scan of the entire collection.
  # For a fast count of the total documents in a collection see `estimated_document_count`.
  #
  # See: [the specification document](https://github.com/mongodb/specifications/blob/master/source/crud/crud.rst#count-api-details).
  def count_documents(
    filter = BSON.new,
    *,
    skip : Int32? = nil,
    limit : Int32? = nil,
    collation : Collation? = nil,
    hint : (String | H)? = nil,
    max_time_ms : Int64? = nil,
    read_preference : ReadPreference? = nil,
    session : Session::ClientSession? = nil,
  ) : Int32 forall H
    pipeline = !filter || filter.empty? ? [BSON.new({"$match": BSON.new})] : [BSON.new({"$match": BSON.new(filter)})]
    skip.try { pipeline << BSON.new({"$skip": skip}) }
    limit.try { pipeline << BSON.new({"$limit": limit}) }
    pipeline << BSON.new({"$group": {"_id": 1, "n": {"$sum": 1}}})
    cursor = self.command(Commands::Aggregate, pipeline: pipeline, session: session, options: {
      collation:       collation,
      hint:            hint.is_a?(String) ? hint : BSON.new(hint),
      max_time_ms:     max_time_ms,
      read_preference: read_preference,
    }) { |result|
      Cursor.new(@database.client, result, limit: limit, session: session)
    }
    if (item = cursor.try(&.next)).is_a? BSON
      item["n"].as(Int32)
    else
      0
    end
  end

  # Gets an estimate of the count of documents in a collection using collection metadata.
  #
  # See: [the specification document](https://github.com/mongodb/specifications/blob/master/source/crud/crud.rst#count-api-details).
  def estimated_document_count(*, max_time_ms : Int64? = nil, read_preference : ReadPreference? = nil, session : Session::ClientSession? = nil) : Int32
    result = self.command(Commands::Count, session: session, options: {
      max_time_ms:     max_time_ms,
      read_preference: read_preference,
    })
    raise Mongo::Error.new("Command failed to return a result") unless result
    result["n"].as(Int32)
  end

  # Finds the distinct values for a specified field across a single collection.
  #
  # NOTE: the results are backed by the "values" array in the distinct command's result
  # document. This differs from aggregate and find, where results are backed by a cursor.
  #
  # NOTE: [for more details, please check the official MongoDB documentation](https://docs.mongodb.com/manual/reference/command/distinct/).
  def distinct(
    key : String,
    *,
    filter = nil,
    read_concern : ReadConcern? = nil,
    collation : Collation? = nil,
    read_preference : ReadPreference? = nil,
    session : Session::ClientSession? = nil,
  ) : Array
    result = self.command(Commands::Distinct, key: key, session: session, options: {
      query:           filter,
      read_concern:    read_concern,
      collation:       collation,
      read_preference: read_preference,
    })
    raise Mongo::Error.new("Command failed to return a result") unless result
    result.values.each.map(&.[1]).to_a
  end

  # Finds the documents matching the model.
  #
  # NOTE: [for more details, please check the official MongoDB documentation](https://docs.mongodb.com/manual/reference/command/find/).
  # NOTE: [for an overview of read operations, check the official manual](https://docs.mongodb.com/manual/core/read-operations-introduction/).
  def find(
    filter = BSON.new,
    *,
    sort = nil,
    projection = nil,
    hint : (String | H)? = nil,
    skip : Int32? = nil,
    limit : Int32? = nil,
    batch_size : Int32? = nil,
    single_batch : Bool? = nil,
    comment : String? = nil,
    max_time_ms : Int64? = nil,
    read_concern : ReadConcern? = nil,
    max = nil,
    min = nil,
    return_key : Bool? = nil,
    show_record_id : Bool? = nil,
    tailable : Bool? = nil,
    oplog_replay : Bool? = nil,
    no_cursor_timeout : Bool? = nil,
    await_data : Bool? = nil,
    allow_partial_results : Bool? = nil,
    allow_disk_use : Bool? = nil,
    collation : Collation? = nil,
    read_preference : ReadPreference? = nil,
    session : Session::ClientSession? = nil,
  ) : Mongo::Cursor forall H
    result = self.command(Commands::Find, filter: filter, session: session, options: {
      sort:                  sort.try { BSON.new(sort) },
      projection:            projection.try { BSON.new(projection) },
      hint:                  hint.is_a?(String) ? hint : BSON.new(hint),
      skip:                  skip,
      limit:                 limit,
      batch_size:            batch_size,
      single_batch:          single_batch,
      comment:               comment,
      max_time_ms:           max_time_ms,
      read_concern:          read_concern,
      max:                   max.try { BSON.new(max) },
      min:                   min.try { BSON.new(min) },
      return_key:            return_key,
      show_record_id:        show_record_id,
      tailable:              tailable,
      oplog_replay:          oplog_replay,
      no_cursor_timeout:     no_cursor_timeout,
      await_data:            await_data,
      allow_partial_results: allow_partial_results,
      allow_disk_use:        allow_disk_use,
      collation:             collation,
      read_preference:       read_preference,
    }) { |result|
      Cursor.new(
        @database.client,
        result,
        await_time_ms: tailable && await_data ? max_time_ms : nil,
        tailable: tailable || false,
        batch_size: batch_size,
        limit: limit,
        session: session
      )
    }
    raise Mongo::Error.new("Command failed to return a result") unless result
    result
  end

  # Finds the document matching the model.
  #
  # NOTE: [for more details, please check the official MongoDB documentation](https://docs.mongodb.com/manual/reference/command/find/).
  def find_one(
    filter = BSON.new,
    *,
    sort = nil,
    projection = nil,
    hint : (String | H)? = nil,
    skip : Int32? = nil,
    comment : String? = nil,
    max_time_ms : Int64? = nil,
    read_concern : ReadConcern? = nil,
    max = nil,
    min = nil,
    return_key : Bool? = nil,
    show_record_id : Bool? = nil,
    oplog_replay : Bool? = nil,
    no_cursor_timeout : Bool? = nil,
    allow_partial_results : Bool? = nil,
    collation : Collation? = nil,
    read_preference : ReadPreference? = nil,
    session : Session::ClientSession? = nil,
  ) : BSON? forall H
    cursor = self.find(
      filter: filter,
      limit: 1,
      single_batch: true,
      batch_size: 1,
      tailable: false,
      await_data: false,
      sort: sort.try { BSON.new(sort) },
      projection: projection.try { BSON.new(projection) },
      hint: hint.is_a?(String) ? hint : BSON.new(hint),
      skip: skip,
      comment: comment,
      max_time_ms: max_time_ms,
      read_concern: read_concern,
      max: max.try { BSON.new(max) },
      min: min.try { BSON.new(min) },
      return_key: return_key,
      show_record_id: show_record_id,
      oplog_replay: oplog_replay,
      no_cursor_timeout: no_cursor_timeout,
      allow_partial_results: allow_partial_results,
      collation: collation,
      read_preference: read_preference,
      session: session
    )
    element = cursor.try &.next
    return element if element.is_a? BSON
    nil
  end
end
