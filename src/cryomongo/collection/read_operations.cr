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
    comment = nil,
    read_concern : ReadConcern? = nil,
    write_concern : WriteConcern? = nil,
    read_preference : ReadPreference? = nil,
    session : Session::ClientSession? = nil,
    timeout_ms : Int64? = nil,
    timeout_mode : Mongo::TimeoutMode? = nil,
    max_await_time_ms : Int64? = nil,
  ) : Mongo::Cursor? forall H
    hint_value = if hint.nil?
                   nil
                 elsif hint.is_a?(String)
                   hint
                 else
                   BSON.new(hint)
                 end
    if timeout_mode.try(&.iteration?) && pipeline.any? { |stage|
         h = stage.is_a?(BSON) ? stage : BSON.new(stage)
         h.has_key?("$out") || h.has_key?("$merge")
       }
      raise Mongo::Error.new("timeoutMode iteration cannot be used with $out or $merge")
    end
    check_max_await_vs_timeout(max_await_time_ms, timeout_ms)
    mode, deadline = cursor_timeout(timeout_ms, timeout_mode, false)
    agg_deadline = mode.iteration? ? deadline.try(&.without_max_time) : deadline
    self.command(Commands::Aggregate, pipeline: pipeline, session: session, deadline: agg_deadline, options: {
      allow_disk_use:             allow_disk_use,
      cursor:                     batch_size.try { {batchSize: batch_size} },
      bypass_document_validation: bypass_document_validation,
      collation:                  collation,
      hint:                       hint_value,
      comment:                    comment,
      max_time_ms:                max_time_ms,
      read_concern:               read_concern,
      write_concern:              write_concern,
      read_preference:            read_preference,
    }) { |result, cmd_session|
      bind_cursor(Cursor.new(@database.client, result, batch_size: batch_size, session: cmd_session, comment: comment, timeout_ms: timeout_ms_for_cursor(timeout_ms), timeout_mode: mode, deadline: deadline), cmd_session)
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
    comment = nil,
    session : Session::ClientSession? = nil,
    timeout_ms : Int64? = nil,
  ) : Int64 forall H
    pipeline = !filter || filter.empty? ? [BSON.new({"$match": BSON.new})] : [BSON.new({"$match": BSON.new(filter)})]
    skip.try { pipeline << BSON.new({"$skip": skip}) }
    limit.try { pipeline << BSON.new({"$limit": limit}) }
    pipeline << BSON.new({"$group": {"_id": 1, "n": {"$sum": 1}}})
    hint_value = if hint.nil?
                   nil
                 elsif hint.is_a?(String)
                   hint
                 else
                   BSON.new(hint)
                 end
    cursor = self.command(Commands::Aggregate, pipeline: pipeline, session: session, timeout_ms: timeout_ms, options: {
      collation:       collation,
      hint:            hint_value,
      max_time_ms:     max_time_ms,
      read_preference: read_preference,
      comment:         comment,
    }) { |result, cmd_session|
      bind_cursor(Cursor.new(@database.client, result, limit: limit, session: cmd_session), cmd_session)
    }
    begin
      if (item = cursor.try(&.next)).is_a? BSON
        bson_count(item["n"])
      else
        0_i64
      end
    ensure
      cursor.try(&.close)
    end
  end

  # Gets an estimate of the count of documents in a collection using collection metadata.
  #
  # See: [the specification document](https://github.com/mongodb/specifications/blob/master/source/crud/crud.rst#count-api-details).
  def estimated_document_count(*, max_time_ms : Int64? = nil, read_preference : ReadPreference? = nil, comment = nil, session : Session::ClientSession? = nil, timeout_ms : Int64? = nil) : Int64
    result = self.command(Commands::Count, session: session, timeout_ms: timeout_ms, options: {
      max_time_ms:     max_time_ms,
      read_preference: read_preference,
      comment:         comment,
    })
    raise Mongo::Error.new("Command failed to return a result") unless result
    bson_count(result["n"])
  end

  private def bson_count(value) : Int64
    case value
    when Int32
      value.to_i64
    when Int64
      value
    when Float64
      value.to_i64
    else
      0_i64
    end
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
    hint : (String | H)? = nil,
    comment = nil,
    session : Session::ClientSession? = nil,
    timeout_ms : Int64? = nil,
  ) : Array forall H
    hint_value = if hint.nil?
                   nil
                 elsif hint.is_a?(String)
                   hint
                 else
                   BSON.new(hint)
                 end
    result = self.command(Commands::Distinct, key: key, session: session, timeout_ms: timeout_ms, options: {
      query:           filter,
      read_concern:    read_concern,
      collation:       collation,
      read_preference: read_preference,
      hint:            hint_value,
      comment:         comment,
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
    comment = nil,
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
    timeout_ms : Int64? = nil,
    timeout_mode : Mongo::TimeoutMode? = nil,
    deadline : Mongo::Deadline? = nil,
  ) : Mongo::Cursor forall H
    sent_batch_size = batch_size
    if (bs = batch_size) && (lim = limit) && bs == lim && bs >= 0
      # CRUD spec: when batchSize == limit, send limit+1 so the server closes the cursor.
      sent_batch_size = bs + 1
    end

    tailable_flag = tailable || false
    await_flag = await_data || false
    if await_flag
      check_max_await_vs_timeout(max_time_ms, timeout_ms)
    end
    mode, computed = cursor_timeout(timeout_ms, timeout_mode, tailable_flag)
    computed = deadline if deadline
    # Tailable awaitData sends maxTimeMS on find. Other iteration cursors must not.
    find_deadline = if tailable_flag && await_flag
                      computed
                    elsif mode.iteration?
                      computed.try(&.without_max_time)
                    else
                      computed
                    end
    deadline = computed

    result = self.command(Commands::Find, filter: filter, session: session, deadline: find_deadline, options: {
      sort:                  sort.try { BSON.new(sort) },
      projection:            projection.try { BSON.new(projection) },
      hint:                  hint.nil? ? nil : (hint.is_a?(String) ? hint : BSON.new(hint)),
      skip:                  skip,
      limit:                 limit,
      batch_size:            sent_batch_size,
      single_batch:          single_batch,
      comment:               comment,
      max_time_ms:           max_time_ms,
      read_concern:          read_concern,
      max:                   max.try { BSON.new(max) },
      min:                   min.try { BSON.new(min) },
      return_key:            return_key,
      show_record_id:        show_record_id,
      tailable:              tailable_flag ? true : tailable,
      oplog_replay:          oplog_replay,
      no_cursor_timeout:     no_cursor_timeout,
      await_data:            await_flag ? true : nil,
      allow_partial_results: allow_partial_results,
      allow_disk_use:        allow_disk_use,
      collation:             collation,
      read_preference:       read_preference,
    }) { |result, cmd_session|
      bind_cursor(Cursor.new(
        @database.client,
        result,
        await_time_ms: tailable_flag && await_flag ? max_time_ms : nil,
        tailable: tailable_flag,
        batch_size: batch_size,
        limit: limit,
        session: cmd_session,
        comment: comment,
        timeout_ms: timeout_ms_for_cursor(timeout_ms),
        timeout_mode: mode,
        deadline: deadline,
      ), cmd_session)
    }
    raise Mongo::Error.new("Command failed to return a result") unless result
    result
  end

  # Same as `#find`, then yield each document and close the cursor.
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
    comment = nil,
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
    timeout_ms : Int64? = nil,
    timeout_mode : Mongo::TimeoutMode? = nil,
    deadline : Mongo::Deadline? = nil,
    &
  ) forall H
    find(
      filter,
      sort: sort,
      projection: projection,
      hint: hint,
      skip: skip,
      limit: limit,
      batch_size: batch_size,
      single_batch: single_batch,
      comment: comment,
      max_time_ms: max_time_ms,
      read_concern: read_concern,
      max: max,
      min: min,
      return_key: return_key,
      show_record_id: show_record_id,
      tailable: tailable,
      oplog_replay: oplog_replay,
      no_cursor_timeout: no_cursor_timeout,
      await_data: await_data,
      allow_partial_results: allow_partial_results,
      allow_disk_use: allow_disk_use,
      collation: collation,
      read_preference: read_preference,
      session: session,
      timeout_ms: timeout_ms,
      timeout_mode: timeout_mode,
      deadline: deadline,
    ).each { |doc| yield doc }
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
    comment = nil,
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
    timeout_ms : Int64? = nil,
    deadline : Mongo::Deadline? = nil,
  ) : BSON? forall H
    cursor = self.find(
      filter: filter,
      limit: 1,
      single_batch: true,
      sort: sort.try { BSON.new(sort) },
      projection: projection.try { BSON.new(projection) },
      hint: hint,
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
      session: session,
      timeout_ms: timeout_ms,
      deadline: deadline
    )
    element = cursor.try &.next
    cursor.try &.close
    return element if element.is_a? BSON
    nil
  end

  # timeoutMode requires timeoutMS at this collection, its database, the client, or the operation.
  protected def cursor_timeout(timeout_ms : Int64?, timeout_mode : Mongo::TimeoutMode?, tailable : Bool) : {Mongo::TimeoutMode, Mongo::Deadline?}
    has_timeout = !timeout_ms.nil? || !@timeout_ms.nil? || !@database.timeout_ms.nil? || @database.client.options.timeout
    if timeout_mode && !has_timeout
      raise Mongo::Error.new("timeoutMode requires timeoutMS")
    end
    mode = timeout_mode || (tailable ? Mongo::TimeoutMode::Iteration : Mongo::TimeoutMode::CursorLifetime)
    if tailable && mode.cursor_lifetime?
      raise Mongo::Error.new("tailable cursors do not support timeoutMode cursorLifetime")
    end
    deadline = unless timeout_ms.nil?
                 Mongo::Deadline.from_timeout_ms(timeout_ms)
               else
                 inherited_deadline
               end
    {mode, deadline}
  end

  protected def timeout_ms_for_cursor(timeout_ms : Int64?) : Int64?
    resolved_timeout_ms(timeout_ms)
  end
end
