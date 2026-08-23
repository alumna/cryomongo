require "./bulk_write/models"
require "./bulk_write/result"

class Mongo::Client
  @@next_operation_id = Atomic(Int64).new(0)

  # Run insert, update, replace, and delete models across mixed namespaces (MongoDB 8.0 `bulkWrite` on `admin`).
  #
  # *verbose_results* defaults to false (`errorsOnly: true` on the wire). Unacknowledged write concern cannot be combined with verbose results or with ordered writes (including the default `ordered: true`).
  def bulk_write(
    models : Array(ClientBulk::WriteModel),
    *,
    ordered : Bool = true,
    bypass_document_validation : Bool? = nil,
    let : BSON? = nil,
    write_concern : WriteConcern? = nil,
    comment = nil,
    verbose_results : Bool = false,
    session : Session::ClientSession? = nil,
    timeout_ms : Int64? = nil,
  ) : ClientBulk::WriteResult
    raise Error::Client.new("client bulkWrite models must not be empty") if models.empty?

    effective_wc = write_concern || @write_concern
    unack = !!effective_wc.try(&.unacknowledged?)
    if unack && verbose_results
      raise Error::Client.new("Cannot request unacknowledged write concern and verbose results")
    end
    if unack && ordered
      raise Error::Client.new("Cannot request unacknowledged write concern and ordered writes")
    end

    deadline = nil.as(Mongo::Deadline?)
    unless timeout_ms.nil?
      if session && session.operation_deadline
        raise Mongo::Error.new("Cannot override timeoutMS inside withTransaction")
      end
      deadline = Mongo::Deadline.from_timeout_ms(timeout_ms)
    end
    deadline ||= session.try(&.operation_deadline)
    deadline ||= Mongo::Deadline.from_options(@options)

    owns_session = session.nil?
    bulk_session = session || Session::ClientSession.new(self)
    operation_id = @@next_operation_id.add(1)

    begin
      run_client_bulk(
        models,
        ordered: ordered,
        bypass_document_validation: bypass_document_validation,
        let: let,
        write_concern: write_concern,
        comment: comment,
        verbose_results: verbose_results,
        unack: unack,
        session: bulk_session,
        deadline: deadline,
        operation_id: operation_id,
      )
    ensure
      bulk_session.end if owns_session && bulk_session.implicit?
    end
  end

  private def run_client_bulk(
    models : Array(ClientBulk::WriteModel),
    *,
    ordered : Bool,
    bypass_document_validation : Bool?,
    let : BSON?,
    write_concern : WriteConcern?,
    comment,
    verbose_results : Bool,
    unack : Bool,
    session : Session::ClientSession,
    deadline : Mongo::Deadline?,
    operation_id : Int64,
  ) : ClientBulk::WriteResult
    dummy = {ops: [] of BSON, ns_info: [] of BSON, options: {errors_only: true, ordered: true}}
    selected = server_selection(Commands::BulkWrite, dummy, PRIMARY_READ_PREFERENCE, deadline)
    max_batch = selected.max_write_batch_size
    max_batch = 100_000 if max_batch <= 0
    max_msg = selected.max_message_size_bytes
    max_msg = 48_000_000 if max_msg <= 0
    limit = max_msg - 1000
    command_size = client_bulk_command_body_size(
      verbose_results: verbose_results,
      ordered: ordered,
      bypass_document_validation: bypass_document_validation,
      comment: comment,
      let: let,
      write_concern: write_concern || @write_concern,
    )

    acc = ClientBulk::WriteResult.empty(verbose: verbose_results, acknowledged: !unack)
    write_errors = {} of Int32 => ClientBulk::WriteError
    write_concern_errors = [] of ClientBulk::WriteConcernError
    extra_labels = Set(String).new
    top_error : Error? = nil
    index = 0

    while index < models.size
      ops, ns_info, next_index = fill_client_bulk_batch(models, index, max_batch, command_size, limit)
      offset = index
      begin
        cmd_result = command(
          Commands::BulkWrite,
          ops: ops,
          ns_info: ns_info,
          options: {
            errors_only:                  !verbose_results,
            ordered:                      ordered,
            bypass_document_validation:   bypass_document_validation,
            comment:                      comment,
            let:                          let,
            write_concern:                write_concern,
          },
          write_concern: write_concern,
          session: session,
          operation_id: operation_id,
          deadline: deadline,
          server_description: selected,
        )
        pinned = session.take_pending_cursor_connection
        begin
          unless unack
            if result = cmd_result.as?(Commands::BulkWrite::Result)
              merge_client_bulk_counts(acc, result)
              collect_client_bulk_wce(result, write_concern_errors, extra_labels)
              drain_client_bulk_cursor(result, models, offset, acc, write_errors, session, deadline, operation_id, pinned)
            end
          end
        ensure
          checkin_connection(pinned) if pinned
        end
      rescue e : Error::WriteConcern
        # Retryable writeConcernError is raised from execute_command so
        # execute_retryable_write can retry. After retries are exhausted,
        # collect it as a writeConcernError (same shape as a non-retryable WCE).
        write_concern_errors << ClientBulk::WriteConcernError.new(e.code, e.message || "", e.details)
        e.error_labels.each { |label| extra_labels << label }
        break
      rescue e : Error::Command
        if acc.any_success? || !write_errors.empty? || !write_concern_errors.empty?
          top_error = e
          break
        else
          raise e
        end
      rescue e : Error
        if acc.any_success? || !write_errors.empty? || !write_concern_errors.empty?
          wrapped = Error::ClientBulkWrite.new(e, write_errors, write_concern_errors, acc.any_success? ? acc : nil)
          extra_labels.each { |label| wrapped.add_error_label(label) }
          raise wrapped
        else
          raise e
        end
      end

      index = next_index
      break if ordered && client_bulk_batch_has_write_error?(write_errors, offset, next_index)
      break if top_error
    end

    if top_error || !write_errors.empty? || !write_concern_errors.empty?
      inner = top_error
      if inner.is_a?(Error::Command) && !acc.any_success? && write_errors.empty? && write_concern_errors.empty?
        raise inner
      end
      wrapped = Error::ClientBulkWrite.new(inner, write_errors, write_concern_errors, acc.any_success? ? acc : nil)
      extra_labels.each { |label| wrapped.add_error_label(label) }
      raise wrapped
    end

    acc
  end

  # Command body size for the batch budget. Do not count `$db`, `lsid`, or `txnNumber` (those sit in the 1000-byte OP_MSG overhead).
  private def client_bulk_command_body_size(
    *,
    verbose_results : Bool,
    ordered : Bool,
    bypass_document_validation : Bool?,
    comment,
    let : BSON?,
    write_concern : WriteConcern?,
  ) : Int32
    BSON.build do |builder|
      builder["bulkWrite"] = 1
      builder["errorsOnly"] = !verbose_results
      builder["ordered"] = ordered
      builder["bypassDocumentValidation"] = bypass_document_validation unless bypass_document_validation.nil?
      builder["comment"] = comment unless comment.nil?
      builder["let"] = let if let
      builder["writeConcern"] = write_concern if write_concern
    end.size
  end

  private def fill_client_bulk_batch(
    models : Array(ClientBulk::WriteModel),
    start : Int32,
    max_batch : Int32,
    command_size : Int32,
    limit : Int32,
  ) : {Array(BSON), Array(BSON), Int32}
    ops = [] of BSON
    ns_info = [] of BSON
    ns_map = {} of String => Int32
    ops_bytes = 0
    ns_bytes = 0
    i = start

    while i < models.size
      model = models[i]
      ns = model.namespace
      extra_ns = 0
      ns_index = ns_map[ns]?
      new_ns_doc = nil.as(BSON?)
      unless ns_index
        new_ns_doc = BSON.new({ns: ns})
        extra_ns = new_ns_doc.size
        ns_index = ns_info.size
      end
      op = ClientBulk.op_document(model, ns_index)
      op_size = op.size

      if !ops.empty? && (ops.size >= max_batch || command_size + ops_bytes + ns_bytes + op_size + extra_ns > limit)
        break
      end

      if ops.empty? && command_size + op_size + extra_ns > limit
        raise Error::Client.new("client bulkWrite operation is too large")
      end

      if doc = new_ns_doc
        ns_map[ns] = ns_info.size
        ns_info << doc
        ns_bytes += extra_ns
      end
      ops << op
      ops_bytes += op_size
      i += 1
    end

    {ops, ns_info, i}
  end

  private def merge_client_bulk_counts(acc : ClientBulk::WriteResult, result : Commands::BulkWrite::Result) : Nil
    acc.inserted_count += result.n_inserted || 0
    acc.upserted_count += result.n_upserted || 0
    acc.matched_count += result.n_matched || 0
    acc.modified_count += result.n_modified || 0
    acc.deleted_count += result.n_deleted || 0
  end

  private def collect_client_bulk_wce(
    result : Commands::BulkWrite::Result,
    write_concern_errors : Array(ClientBulk::WriteConcernError),
    extra_labels : Set(String),
  ) : Nil
    wce = result.write_concern_error
    return unless wce
    write_concern_errors << ClientBulk::WriteConcernError.new(wce.code, wce.errmsg, wce.err_info)
    wce.error_labels.try &.each { |label| extra_labels << label }
  end

  private def client_bulk_batch_has_write_error?(write_errors : Hash(Int32, ClientBulk::WriteError), offset : Int32, next_index : Int32) : Bool
    write_errors.each_key.any? { |idx| idx >= offset && idx < next_index }
  end

  # Drain firstBatch / getMore on the same session (and load-balanced socket). Do not use Mongo::Cursor: Cursor#close ends an implicit session.
  private def drain_client_bulk_cursor(
    result : Commands::BulkWrite::Result,
    models : Array(ClientBulk::WriteModel),
    offset : Int32,
    acc : ClientBulk::WriteResult,
    write_errors : Hash(Int32, ClientBulk::WriteError),
    session : Session::ClientSession,
    deadline : Mongo::Deadline?,
    operation_id : Int64,
    pinned : Mongo::Connection?,
  ) : Nil
    cursor = result.cursor
    return unless cursor

    cursor.first_batch.each { |doc| apply_client_bulk_cursor_doc(doc, models, offset, acc, write_errors) }
    cursor_id = cursor.id
    cursor_ns = cursor.ns
    server = session.last_operation_server

    while cursor_id != 0
      db, coll = split_cursor_ns(cursor_ns)
      begin
        more = command(
          Commands::GetMore,
          database: db,
          collection: coll,
          cursor_id: cursor_id,
          session: session,
          server_description: server,
          connection: pinned,
          deadline: deadline,
          operation_id: operation_id,
        )
        unless more.is_a?(Commands::GetMore::Result)
          break
        end
        more.cursor.next_batch.each { |doc| apply_client_bulk_cursor_doc(doc, models, offset, acc, write_errors) }
        cursor_id = more.cursor.id
        cursor_ns = more.cursor.ns
      rescue e
        kill_client_bulk_cursor(cursor_id, cursor_ns, session, server, pinned, deadline)
        raise e
      end
    end
  end

  private def split_cursor_ns(ns : String) : {String, String}
    parts = ns.split('.', 2)
    db = parts[0]
    coll = parts.size > 1 ? parts[1] : ""
    {db, coll}
  end

  private def kill_client_bulk_cursor(
    cursor_id : Int64,
    ns : String,
    session : Session::ClientSession,
    server : SDAM::ServerDescription?,
    pinned : Mongo::Connection?,
    deadline : Mongo::Deadline?,
  ) : Nil
    return if cursor_id == 0
    db, coll = split_cursor_ns(ns)
    begin
      command(
        Commands::KillCursors,
        database: db,
        collection: coll,
        cursor_ids: [cursor_id],
        session: session,
        server_description: server,
        connection: pinned,
        deadline: deadline,
      )
    rescue
    end
  end

  private def apply_client_bulk_cursor_doc(
    doc : BSON,
    models : Array(ClientBulk::WriteModel),
    offset : Int32,
    acc : ClientBulk::WriteResult,
    write_errors : Hash(Int32, ClientBulk::WriteError),
  ) : Nil
    idx = offset + bson_int32(doc["idx"]?)
    unless cursor_ok?(doc["ok"]?)
      unless write_errors.has_key?(idx)
        write_errors[idx] = ClientBulk::WriteError.new(
          idx,
          bson_int32(doc["code"]?),
          doc["errmsg"]?.try(&.as?(String)) || "",
          doc["errInfo"]?.try(&.as?(BSON)),
        )
      end
      return
    end
    return unless 0 <= idx && idx < models.size

    model = models[idx]
    case model
    when ClientBulk::InsertOne
      if inserts = acc.insert_results
        inserts[idx] = ClientBulk::InsertResult.new(model.inserted_id)
      end
    when ClientBulk::UpdateOne, ClientBulk::UpdateMany, ClientBulk::ReplaceOne
      if updates = acc.update_results
        upserted_id = nil.as(BSON::Value?)
        if u = doc["upserted"]?
          upserted_id = u.is_a?(BSON) ? u["_id"]? : u
        end
        updates[idx] = ClientBulk::UpdateResult.new(
          bson_int32(doc["n"]?),
          bson_int32(doc["nModified"]?),
          upserted_id,
        )
      end
    when ClientBulk::DeleteOne, ClientBulk::DeleteMany
      if deletes = acc.delete_results
        deletes[idx] = ClientBulk::DeleteResult.new(bson_int32(doc["n"]?))
      end
    end
  end

  private def bson_int32(value) : Int32
    case value
    when Int32
      value
    when Int64
      value.to_i32
    when Float64
      value.to_i32
    else
      0
    end
  end

  private def cursor_ok?(value) : Bool
    value == 1 || value == 1.0
  end
end
