class Mongo::Client
  # Execute a command on the server.
  #
  # ```
  # # First argument is the `Mongo::Commands`.
  # client.command(Mongo::Commands::DropDatabase, database: "database_name")
  # ```
  def command(
    command,
    write_concern : WriteConcern? = nil,
    read_concern : ReadConcern? = nil,
    read_preference : ReadPreference? = nil,
    server_description : SDAM::ServerDescription? = nil,
    session : Session::ClientSession? = nil,
    operation_id : Int64? = nil,
    connection : Mongo::Connection? = nil,
    deadline : Mongo::Deadline? = nil,
    **args,
    &block
  )
    # Create an implicit session only when the caller did not pass one.
    # The caller (bulk, change stream, cursor) owns ending a session it created.
    # Fiber-local implicit sessions stay until the client closes or the fiber dies.
    # endSessions during pool close must not check out from the pool.
    owns_session = false
    if session.nil?
      if command.is_a?(Commands::EndSessions)
        session = Session::ClientSession.new(self, pooled: false)
        owns_session = true
      else
        session = implicit_session_for_fiber
      end
    end

    # After commit the session stays pinned so commit can be retried on the
    # same mongos. Any other operation must unpin.
    if (s = session)
      st = s.transaction_state
      unless st.starting? || st.in_progress? || command.is_a?(Commands::CommitTransaction) || command.is_a?(Commands::AbortTransaction)
        s.unpin
      end
    end

    result = begin
      if session && session.is_transaction? && !command.is_a?(Commands::CommitTransaction) && !command.is_a?(Commands::AbortTransaction)
        session.insert_transaction {
          internal_command(
            command,
            **args,
            write_concern: write_concern,
            read_concern: read_concern,
            read_preference: read_preference,
            server_description: server_description,
            session: session,
            operation_id: operation_id,
            connection: connection,
            deadline: resolve_deadline(deadline, session),
            end_implicit_session: owns_session,
          )
        }
      else
        internal_command(
          command,
          **args,
          write_concern: write_concern,
          read_concern: read_concern,
          read_preference: read_preference,
          server_description: server_description,
          session: session,
          operation_id: operation_id,
          connection: connection,
          deadline: resolve_deadline(deadline, session),
          end_implicit_session: owns_session,
        )
      end
    end
    result.try { |r|
      yield r, session # , server_description
    }
  rescue e
    if command.is_a? Commands::AbortTransaction
      # Ignore abort transaction errors
      # see: https://github.com/mongodb/specifications/blob/master/source/transactions/transactions.rst#drivers-ignore-all-aborttransaction-errors
      return nil
    end

    raise e
  end

  # :ditto:
  def command(
    command cmd,
    write_concern : WriteConcern? = nil,
    read_concern : ReadConcern? = nil,
    read_preference : ReadPreference? = nil,
    server_description : SDAM::ServerDescription? = nil,
    session : Session::ClientSession? = nil,
    operation_id : Int64? = nil,
    connection : Mongo::Connection? = nil,
    deadline : Mongo::Deadline? = nil,
    **args,
  )
    self.command(cmd, write_concern, read_concern, read_preference, server_description, session, operation_id, connection, deadline, **args) { |result|
      result
    }
  end

  private def internal_command(
    command,
    write_concern : WriteConcern? = nil,
    read_concern : ReadConcern? = nil,
    read_preference : ReadPreference? = nil,
    server_description : SDAM::ServerDescription? = nil,
    session : Session::ClientSession? = nil,
    operation_id : Int64? = nil,
    connection : Mongo::Connection? = nil,
    deadline : Mongo::Deadline? = nil,
    end_implicit_session : Bool = true,
    **args,
  )
    # Mix collection/database/client/options read and write concerns considering the precedence rules.
    args = WithWriteConcern.mix_write_concern(command, args, write_concern || @write_concern, session: session)
    args = WithReadConcern.mix_read_concern(command, args, read_concern || @read_concern, session: session)

    # Determines the read preference to apply to the command
    if WithReadPreference.must_use_primary_command?(command, args)
      read_preference = PRIMARY_READ_PREFERENCE
    else
      if session.is_transaction?
        read_preference = session.current_transaction_options.read_preference || read_preference || @read_preference || PRIMARY_READ_PREFERENCE
      else
        read_preference = read_preference || @read_preference || PRIMARY_READ_PREFERENCE
      end
    end

    # See: https://github.com/mongodb/specifications/blob/master/source/transactions/transactions.rst#readpreference
    if session.is_transaction? && read_preference.mode != "primary"
      raise Error::Transaction.new("read preference in a transaction must be primary.")
    end

    # Determine whether the request is acknowledged and prohibit some operations.
    acknowledged = acknowledged?(args, session)

    # Session could be pinned to a specific mongos. A caller-supplied server
    # (client bulkWrite pre-selects for batch size) must not pick the other mongos.
    if pin = session.server_description
      server_description = pin
    end

    retryable_command = acknowledged && command.is_a?(Commands::Retryable) && command.retryable?(**args, session: session)

    if (retryable_command && @options.retry_writes || command.is_a?(Commands::AlwaysRetryable)) && command.is_a?(Commands::WriteCommand) && command.write_command?
      execute_retryable_write(
        command,
        session,
        read_preference,
        server_description,
        operation_id,
        end_implicit_session,
        connection,
        deadline,
        **args
      )
    elsif retryable_command && @options.retry_reads && command.is_a?(Commands::ReadCommand) && command.read_command?
      execute_retryable_read(
        command,
        session,
        read_preference,
        server_description,
        operation_id,
        end_implicit_session,
        connection,
        deadline,
        **args
      )
    else
      execute_once_or_overload_retry(
        command,
        session,
        read_preference,
        server_description,
        operation_id,
        end_implicit_session,
        connection,
        deadline,
        **args
      )
    end
  end

  private def execute_command(
    command,
    session : Session::ClientSession,
    read_preference : ReadPreference,
    server_description : SDAM::ServerDescription,
    connection : Mongo::Connection,
    operation_id : Int64? = nil,
    end_implicit_session : Bool = true,
    deadline : Mongo::Deadline? = nil,
    owns_connection : Bool = true,
    **args,
  )
    execute_command(command, session, read_preference, server_description, connection, operation_id, end_implicit_session, deadline, owns_connection, **args) { }
  end

  private def execute_command(
    command,
    session : Session::ClientSession,
    read_preference : ReadPreference,
    server_description : SDAM::ServerDescription,
    connection : Mongo::Connection,
    operation_id : Int64? = nil,
    end_implicit_session : Bool = true,
    deadline : Mongo::Deadline? = nil,
    owns_connection : Bool = true,
    **args,
    &
  )
    duration_start = Time.instant
    request_id = 0_i64
    command_started = false
    command_name = command.name
    address = connection.server_description.address
    database_name = ""
    want_apm = @commands_observable.has_subscribers?
    want_log = want_command_logs?
    wrapped_csot_io = false

    # Deadline at first byte: leftover 0 still sends so commandStarted
    # fires (2nd find / getMore / 3rd insert). AwaitReadIO raises on
    # read without a leftover-0 last-read. Do not check! here.
    # Drop a leaked handshake wrap so this command uses timeoutMS or
    # socketTimeoutMS, not connectTimeoutMS / an infinite slice retry.
    connection.unwrap_deadline_io
    wrapped_csot_io = wrap_command_io(connection, deadline)

    # Load-balanced transactions keep this socket even if this command fails
    # with a non-transient error.
    if @options.load_balanced && owns_connection && session.is_transaction? && (session.transaction_state.starting? || session.transaction_state.in_progress?)
      session.pin_connection(connection)
      mark_transaction_pin(connection)
      owns_connection = false
    end

    if session.options.snapshot && server_description.max_wire_version < 13
      raise Error::Client.new("Snapshot reads require MongoDB 5.0 or later")
    end

    # Reject for this special case.
    if command == Mongo::Commands::FindAndModify && args["options"]?.try(&.["hint"]?) && server_description.max_wire_version < 8
      raise Mongo::Error.new "The hint option is not supported by MongoDB servers < 4.2"
    end

    # Mix the collection/database/client/options read preferences.
    args = WithReadPreference.mix_read_preference(command, args, read_preference, topology, server_description)

    # Determine whether the request is acknowledged.
    unacknowledged = !acknowledged?(args, session, validate: false)

    # Extract the actual BSON depending on the target command.
    body, sequences = command.command(**args)

    if unacknowledged
      has_hint = body.has_key?("hint")
      if !has_hint && sequences
        has_hint = true if sequences.values.any? { |docs|
                             docs.is_a?(Array) && docs.any? { |doc| doc.is_a?(BSON) && doc.has_key?("hint") }
                           }
      end

      if has_hint
        if command == Commands::Update || command == Commands::FindAndModify
          if server_description.max_wire_version < 8
            raise Mongo::Error.new("Option hint is prohibited when performing an unacknowledged write on servers < 4.2.")
          end
        elsif command == Commands::Delete
          if server_description.max_wire_version < 9
            raise Mongo::Error.new("Option hint is prohibited when performing an unacknowledged write on servers < 4.4.")
          end
        end
      end
    end

    flag_bits = unacknowledged ? Messages::OpMsg::Flags::MoreToCome : Messages::OpMsg::Flags::None

    # Auto-encryption: one nil check. No extra alloc when it is off.
    # Encrypt before session fields so lsid / txnNumber are appended after.
    # Key-vault and listCollections set a per-fiber bypass (no re-entry).
    if auto = @auto_encryption
      unless auto.bypassing?
        unless auto.skip_encrypt?
          body = auto.encrypt_command(body, sequences)
          sequences = nil
        end
      end
    end

    # Apply session rules, then retry extras, then Server API.
    session.mark_used
    body = apply_session_fields(body, session, unacknowledged, command, server_description, **args)
    body = (yield body) || body
    body = apply_server_api(body)
    body = apply_csot_max_time(body, command, deadline, server_description)
    body = strip_wtimeout_if_csot(body, deadline)

    # Create the OP_MSG message to send.
    op_msg = Messages::OpMsg.new(body, flag_bits: flag_bits)
    sequences.try &.each { |key, documents|
      op_msg.sequence(key.to_s, contents: documents)
    }

    # Send the command.
    connection.send(op_msg, command) { |message|
      if want_apm || want_log
        request_id = message.header.request_id.to_i64
        command_started = true
        payload = op_msg.safe_payload(command)
        if db = op_msg.body["$db"]?.try(&.as?(String))
          database_name = db
        end
        if want_apm
          @commands_observable.broadcast(Monitoring::Commands::CommandStartedEvent.new(
            command_name: command_name,
            request_id: request_id,
            operation_id: operation_id,
            address: address,
            command: payload,
            database_name: database_name,
            service_id: connection.service_id,
            driver_connection_id: connection.connection_id,
            server_connection_id: connection.server_connection_id
          ))
        end
        log_command_started(
          command_name, database_name, request_id, operation_id, address, payload,
          connection.connection_id, connection.server_connection_id, connection.service_id
        )
      end
    }

    # If the write is unacknowledged - early return.
    if unacknowledged
      if want_apm || want_log
        reply = BSON.new({ok: 1})
        duration = duration_start.elapsed
        if want_apm
          @commands_observable.broadcast(Monitoring::Commands::CommandSucceededEvent.new(
            command_name: command_name,
            request_id: request_id,
            operation_id: operation_id,
            address: address,
            duration: duration,
            reply: reply,
            service_id: connection.service_id,
            driver_connection_id: connection.connection_id,
            server_connection_id: connection.server_connection_id
          ))
        end
        log_command_succeeded(
          command_name, database_name, request_id, operation_id, address, duration, reply,
          connection.connection_id, connection.server_connection_id, connection.service_id
        )
      end

      return nil
    end

    # Receive the server sent OP_MSG.
    reply_error = nil.as(Exception?)
    op_msg = connection.receive do |message|
      op_msg = message.contents.as(Messages::OpMsg)
      duration = duration_start.elapsed
      reply_error = op_msg.error?
      # CLAM: ok:1 is CommandSucceeded even when writeErrors or writeConcernError is present.
      # bulkWrite ok:1 plus writeConcernError is also a success for APM. The caller drains the cursor, then raises at the end.
      command_ok = op_msg.valid?

      # Monitor.
      if want_apm || want_log
        payload = op_msg.safe_payload(command)
        if reply_error && !command_ok
          failure = Monitoring::Redact.failure(command_name, reply_error, op_msg.body)
          if want_apm
            @commands_observable.broadcast(Monitoring::Commands::CommandFailedEvent.new(
              command_name: command_name,
              request_id: message.header.response_to.to_i64,
              operation_id: operation_id,
              address: address,
              duration: duration,
              reply: payload,
              failure: failure,
              service_id: connection.service_id,
              driver_connection_id: connection.connection_id,
              server_connection_id: connection.server_connection_id
            ))
          end
          log_command_failed(
            command_name, database_name, message.header.response_to.to_i64, operation_id, address, duration, failure,
            connection.connection_id, connection.server_connection_id, connection.service_id
          )
        else
          if want_apm
            @commands_observable.broadcast(Monitoring::Commands::CommandSucceededEvent.new(
              command_name: command_name,
              request_id: message.header.response_to.to_i64,
              operation_id: operation_id,
              address: address,
              duration: duration,
              reply: payload,
              service_id: connection.service_id,
              driver_connection_id: connection.connection_id,
              server_connection_id: connection.server_connection_id
            ))
          end
          log_command_succeeded(
            command_name, database_name, message.header.response_to.to_i64, operation_id, address, duration, payload,
            connection.connection_id, connection.server_connection_id, connection.service_id
          )
        end
      end
    end

    # Parse as a base result.
    base_result = Commands::Common::BaseResult.from_bson(op_msg.body)

    # Update the stored cluster time.
    if cluster_time = base_result.cluster_time
      advance_cluster_time(cluster_time)
      session.advance_cluster_time(cluster_time) if session
    end

    if operation_time = base_result.operation_time
      session.advance_operation_time(operation_time) if session
    end

    if session && session.options.snapshot && session.snapshot_time.nil?
      at_cluster_time = if cursor_bson = op_msg.body["cursor"]?.try(&.as?(BSON))
                          cursor_bson["atClusterTime"]?.try(&.as?(BSON::Timestamp))
                        else
                          op_msg.body["atClusterTime"]?.try(&.as?(BSON::Timestamp))
                        end
      session.snapshot_time = at_cluster_time if at_cluster_time
    end

    # Update the session recovery token if needed.
    # see: https://github.com/mongodb/specifications/blob/master/source/transactions/transactions.rst#recoverytoken-field
    if session.is_transaction? && (token = base_result.recovery_token)
      session.recovery_token = token
    end

    # Raise if the server replied with an error.
    # bulkWrite writeConcernError is not raised here so the caller can drain the cursor and continue batches.
    if (error = reply_error) && !(command == Commands::BulkWrite && error.is_a?(Error::WriteConcern))
      raise wrap_csot_timeout(error, deadline)
    end

    # Decrypt after APM CommandSucceeded (spec). Skip when this fiber is
    # fetching keys or collection info. Still decrypt when bypass_auto_encryption.
    result_body = op_msg.body
    if auto = @auto_encryption
      unless auto.bypassing?
        result_body = auto.decrypt_reply(result_body)
      end
    end

    # Parse and return the body as a custom Result type.
    result = command.result(result_body)
    session.last_operation_server = server_description

    # APM already recorded Succeeded for bulkWrite ok:1 + writeConcernError.
    # If the write is retryable, raise so execute_retryable_write can retry.
    # Do not pin or return this attempt: the leftover cursor must not be drained.
    if command == Commands::BulkWrite && (wce_error = reply_error).is_a?(Error::WriteConcern)
      if @options.retry_writes && command.responds_to?(:retryable?) && command.retryable?(**args, session: session) && wce_error.retryable_write?
        if result.is_a?(Commands::BulkWrite::Result)
          if cursor = result.cursor
            kill_client_bulk_cursor(cursor.id, cursor.ns, session, server_description, connection, deadline)
          end
        end
        raise wrap_csot_timeout(wce_error, deadline)
      end
    end

    if @options.load_balanced && owns_connection
      if (cid = cursor_id_of(result)) && cid != 0
        session.pending_cursor_connection = connection
        mark_cursor_pin(connection)
        owns_connection = false
      end
    end
    result
  rescue error
    started_name = command_name
    started_address = address
    if command_started && started_name && started_address && error.is_a?(NetworkError)
      duration = duration_start.try(&.elapsed) || Time::Span.zero
      failure = error
      if want_apm
        @commands_observable.broadcast(Monitoring::Commands::CommandFailedEvent.new(
          command_name: started_name,
          request_id: request_id || 0_i64,
          operation_id: operation_id,
          address: started_address,
          duration: duration,
          reply: BSON.new,
          failure: failure,
          service_id: connection.service_id,
          driver_connection_id: connection.connection_id,
          server_connection_id: connection.server_connection_id
        ))
      end
      log_command_failed(
        started_name, database_name || "", request_id || 0_i64, operation_id, started_address, duration, failure,
        connection.connection_id, connection.server_connection_id, connection.service_id
      )
    end
    if error.is_a?(NetworkError)
      keep_pin = io_timeout?(error) &&
                 !owns_connection &&
                 @options.load_balanced &&
                 connection.awaiting_reply? &&
                 !connection.socket.closed?
      if keep_pin
        # Timeout with no reply bytes yet. Keep the pin so close() can drain
        # the late getMore and send killCursors on the same socket.
        connection.mark_pending_reply
      else
        # Mark the socket dead so checkin uses reason "error", not "stale".
        connection.close
      end
      Mongo::Log.error(exception: error) { "Network error" } unless server_description
      if connection.interrupted_by_clear?
        address = server_description.try(&.address) || connection.server_description.address
        # CMAP: interrupt SHOULD be PoolClearedError. Using Network keeps
        # retryReads:false from retrying in execute_once_or_overload_retry
        # (that path retries PoolCleared). Retryable reads/writes still retry.
        error = Error::Network.new("Connection to #{address} interrupted due to server monitor timeout")
      else
        # After handshake, a socket timeout is a slow operation, not a dead server.
        # closeConnection / reset still mark Unknown and clear the pool.
        kind = io_timeout?(error) ? SDAM::ApplicationError::Kind::Timeout : SDAM::ApplicationError::Kind::Network
        action = SDAM::ApplicationError.decide(kind, SDAM::ApplicationError::Phase::AfterHandshake, stale: false)
        unless action.ignore? || keep_pin
          # After handshake, a non-timeout network error marks Unknown and
          # clears the pool. A stale-generation error is ignored.
          if @options.load_balanced
            handle_load_balanced_error(server_description, connection, error)
          else
            handle_application_error(server_description, connection, error, network: true, shutdown: true)
          end
        end
        error = Error::Network.new(error)
      end
      session.try &.dirty = true
      if (d = deadline) && !d.infinite? && !error.is_a?(Error::PoolCleared)
        # A leaked Darwin slice is io_timeout? while the CSOT deadline still
        # has time. Raise Timeout only when the deadline has passed. Linux
        # CSOT already waits until expiry, so d.expired? is true there.
        if d.expired?
          error = Error::Timeout.new("socket timeout: #{error.message}", cause: error)
        end
      end
      # Only retryable writes (retryWrites enabled) get RetryableWriteError on a network error.
      if error.is_a?(Error::Network) && @options.retry_writes && command.is_a?(Commands::WriteCommand) && command.write_command?(**args) && command.responds_to?(:retryable?) && command.retryable?(**args, session: session)
        error.add_error_label("RetryableWriteError")
      end
    end

    if error.is_a?(Mongo::Error::Command)
      Mongo::Log.error { "Command error: #{error}" }
      # see: https://github.com/mongodb/specifications/blob/master/source/server-discovery-and-monitoring/server-discovery-and-monitoring.rst#not-master-and-node-is-recovering
      if error.state_change?
        if @options.load_balanced
          handle_load_balanced_error(server_description, connection, error) if error.shutdown?
        else
          apply_state_change_error(server_description, error, connection)
        end
      end
    end

    if error.is_a?(Mongo::Error)
      if command.is_a? Commands::CommitTransaction
        error.add_unknown_transaction_label
      else
        error.add_transient_transaction_label
      end

      # Transient errors unpin. Unknown commit result also unpins before a retry
      # (transactions spec "When to unpin"). Successful commit stays pinned.
      if error.transient_transaction? || (command.is_a?(Commands::CommitTransaction) && error.unknown_transaction?)
        session.try &.unpin
      end
    end

    raise error
  ensure
    connection.unwrap_deadline_io if wrapped_csot_io
    session.majority_commit_wc = false
    release_connection(connection) if connection && owns_connection
    if end_implicit_session && !keeps_implicit_session?(result)
      session.try &.end if session.try(&.implicit?)
    end
  end

  # Load-balanced: do not mark the balancer Unknown. Clear only sockets with
  # this serviceId. Stale sockets (older generation) are ignored.
  private def handle_load_balanced_error(server_description : SDAM::ServerDescription?, connection : Mongo::Connection, error : Exception) : Nil
    return unless connection.handshake_complete
    pool = pool_for(connection)
    return if pool && pool.stale?(connection)
    sid = connection.service_id
    return unless sid
    desc = server_description
    return unless desc
    Mongo::Log.error(exception: error) { "Error with load balancer service #{sid} at #{desc.address}" }
    clear_connection_pool(desc, sid)
  end

  # Mark the server Unknown after a not-master / recovering error, unless the
  # error is stale (older pool generation or topologyVersion).
  private def apply_state_change_error(server_description : SDAM::ServerDescription?, error : Mongo::Error::Command, connection : Mongo::Connection? = nil) : Nil
    handle_application_error(server_description, connection, error, network: false, shutdown: error.shutdown?)
  end

  # SDAM application error: ignore stale generation / topologyVersion so two
  # concurrent shutdowns emit one Unknown and one poolClearedEvent. Equal TV
  # still marks Unknown while the type is Primary. Mongos / load-balanced
  # stay spec-stale. Pool clear stays under the topology lock (SDAM spec).
  private def handle_application_error(
    server_description : SDAM::ServerDescription?,
    connection : Mongo::Connection?,
    error : Exception,
    *,
    network : Bool,
    shutdown : Bool,
  ) : Nil
    desc = server_description
    return unless desc

    if network
      Mongo::Log.error(exception: error) { "I/O error with server address: #{desc.address}" }
    end

    description = SDAM::ServerDescription.new(desc.address)
    unless network
      description.min_wire_version = desc.min_wire_version
      description.max_wire_version = desc.max_wire_version
    end
    description.error = error.message
    description.last_update_time = desc.last_update_time
    if (cmd_err = error.as?(Mongo::Error::Command)) && (tv = cmd_err.topology_version)
      description.topology_version = BSON.new(tv.data)
    end

    pool = if conn = connection
             pool_for(conn) || pool_at(desc.address)
           else
             pool_at(desc.address)
           end

    applied = topology.apply_application_error(desc, description, connection, pool) do
      clear_pool(desc) if network || shutdown
    end
    return unless applied
    @monitors.find(&.server_description.address.== desc.address).try &.cancel_check
  end

  # CSOT: slice until leftover timeoutMS. Darwin without CSOT: slice until
  # socketTimeoutMS (or until data if unset) so a false kqueue timeout is
  # retried but a failPoint blockConnection still expires. Linux without
  # CSOT keeps a single socket wait (hot path).
  private def wrap_command_io(connection : Mongo::Connection, deadline : Mongo::Deadline?) : Bool
    if (d = deadline) && !d.infinite?
      left = d.remaining
      # Deadline at first byte: leftover 0 still wraps so the send can
      # run. AwaitReadIO raises on read (no leftover-0 last-read).
      expire_at = left <= Time::Span.zero ? Time.instant : Time.instant + left
      # Do not set leftover timeoutMS as one socket wait. Darwin kqueue can
      # fire that wait early (bulkWrite UTF then sees two inserts, not three).
      # Slices retry a premature IO::TimeoutError or ETIMEDOUT until the
      # CSOT deadline.
      connection.apply_timeout(nil)
      return connection.wrap_deadline_io(expire_at)
    end
    sock = Mongo::Connection.uri_timeout(@options.socket_timeout)
    {% if flag?(:darwin) %}
      connection.apply_timeout(nil)
      expire_at = sock ? Time.instant + sock : nil
      connection.wrap_deadline_io(expire_at)
    {% else %}
      connection.apply_timeout(sock)
      false
    {% end %}
  end

  # Darwin may surface ETIMEDOUT as Socket::Error, not IO::TimeoutError.
  private def io_timeout?(error : Exception?) : Bool
    return false unless error
    return true if error.is_a?(IO::TimeoutError)
    if error.responds_to?(:os_error)
      os = error.os_error
      return true if os == Errno::ETIMEDOUT
    end
    io_timeout?(error.cause)
  end

  private def resolve_deadline(deadline : Mongo::Deadline?, session : Session::ClientSession?) : Mongo::Deadline?
    return deadline if deadline
    if d = session.try(&.operation_deadline)
      return d
    end
    if ms = session.try(&.options.default_timeout_ms)
      return Mongo::Deadline.from_timeout_ms(ms)
    end
    Mongo::Deadline.from_options(@options)
  end

  # CSOT: remaining timeout minus min RTT. getMore on a non-awaitData cursor
  # must not get maxTimeMS. AwaitData getMore already has maxTimeMS (maxAwaitTimeMS).
  private def apply_csot_max_time(body : BSON, command, deadline : Mongo::Deadline?, server_description : SDAM::ServerDescription) : BSON
    return body unless deadline
    return body if deadline.infinite?
    return body if command != Commands::GetMore && !deadline.send_max_time?

    # Deadline at first byte: leftover 0 still sends. Skip maxTimeMS;
    # AwaitReadIO raises on read.
    if deadline.remaining <= Time::Span.zero
      return body
    end

    live = topology.servers.find { |s| s.address == server_description.address }
    min_rtt = (live || server_description).min_round_trip_time
    max_time_ms = deadline.max_time_ms(min_rtt)
    unless max_time_ms
      raise Error::Timeout.new("remaining timeoutMS is less than server min RTT")
    end

    if command == Commands::GetMore
      return body unless body.has_key?("maxTimeMS")
      existing = body["maxTimeMS"]?
      existing_ms = case existing
                    when Int
                      existing.to_i64
                    else
                      max_time_ms
                    end
      capped = existing_ms < max_time_ms ? existing_ms : max_time_ms
      return body.copy_with({maxTimeMS: capped})
    end

    body.copy_with({maxTimeMS: max_time_ms})
  end

  # timeoutMS replaces wTimeoutMS. Drop wtimeout from writeConcern when CSOT is on.
  private def strip_wtimeout_if_csot(body : BSON, deadline : Mongo::Deadline?) : BSON
    return body unless deadline
    return body if deadline.infinite?
    return body unless body.has_key?("writeConcern")
    wc = body["writeConcern"]?
    return body unless wc.is_a?(BSON)
    return body unless wc.has_key?("wtimeout") || wc.has_key?("wtimeoutMS")
    other = false
    wc.each { |k, _|
      other = true unless k == "wtimeout" || k == "wtimeoutMS"
    }
    if other
      new_wc = BSON.build { |b|
        wc.each { |k, v|
          b[k] = v unless k == "wtimeout" || k == "wtimeoutMS"
        }
      }
      return body.copy_with({writeConcern: new_wc})
    end
    BSON.build do |builder|
      body.each { |key, value, code|
        next if key == "writeConcern"
        if value.is_a?(BSON) && code.array?
          builder.append_array(key, value)
        else
          builder[key] = value
        end
      }
    end
  end

  # timeoutMS turns MaxTimeMSExpired (code 50) into Error::Timeout.
  private def wrap_csot_timeout(error : Exception, deadline : Mongo::Deadline?) : Exception
    return error unless deadline
    return error if deadline.infinite?
    case error
    when Error::CommandWrite
      if error.errors.any?(&.max_time_ms_expired?)
        return Error::Timeout.new("MaxTimeMSExpired: #{error.message}", cause: error)
      end
    when Error::Command
      if error.max_time_ms_expired?
        return Error::Timeout.new("MaxTimeMSExpired: #{error.message}", cause: error)
      end
    end
    error
  end

  # Write session fields with one builder append instead of many `[]=`.
  private def apply_session_fields(
    body : BSON,
    session : Session::ClientSession,
    unacknowledged : Bool,
    command,
    _server_description : SDAM::ServerDescription,
    **args,
  ) : BSON
    in_txn = session.is_transaction?
    # After a state-change the only mongos can be Unknown and LSTM is cleared,
    # so supports_sessions? is false. Implicit retryable writes still need lsid.
    # Unacknowledged implicit writes never send session fields.
    return body if unacknowledged && session.implicit? && !in_txn

    if unacknowledged
      # Sessions are not compatible with unacknowledged writes
      raise Mongo::Error.new("Unacknowledged writes are incompatible with sessions.") unless session.implicit?
    end

    add_lsid = !unacknowledged
    cluster_time = topology.supports_cluster_time? ? gossip_cluster_time(session) : nil
    start_transaction = false
    add_txn_fields = false
    read_concern = nil.as(ReadConcern?)
    has_read_concern = body.has_key?("readConcern")

    if in_txn
      if session.transitions_from.try(&.starting?) || session.apply_transaction_read_concern?
        start_transaction = true
      end
      add_txn_fields = true
    end

    # getMore and killCursors must not get readConcern (including afterClusterTime).
    takes_read_concern = !command.is_a?(Commands::GetMore) &&
                         !command.is_a?(Commands::KillCursors) &&
                         !command.is_a?(Commands::EndSessions) &&
                         !command.is_a?(Commands::Hello)

    if takes_read_concern
      if session.options.snapshot && !has_read_concern
        read_concern = ReadConcern.new(level: "snapshot", at_cluster_time: session.snapshot_time)
      elsif session.is_transaction? && start_transaction && !has_read_concern
        read_concern = session.current_transaction_options.read_concern
      end
      if session.is_transaction? && start_transaction
        session.apply_transaction_read_concern = false
      end

      if !session.is_transaction? && session.options.causal_consistency && read_concern.nil? && !has_read_concern
        if operation_time = session.operation_time
          is_read = command.responds_to?(:read_command?) && command.read_command?(**args)
          is_write = command.responds_to?(:write_command?) && command.write_command?(**args)
          if is_read || is_write
            read_concern = ReadConcern.new(after_cluster_time: operation_time)
          end
        end
      end
    end

    return body unless add_lsid || cluster_time || add_txn_fields || read_concern || session.majority_commit_wc?

    body.append do |builder|
      builder["lsid"] = session.session_id if add_lsid
      builder["$clusterTime"] = cluster_time if cluster_time
      if add_txn_fields
        builder["startTransaction"] = true if start_transaction
        builder["txnNumber"] = session.txn_number
        builder["autocommit"] = false
      end
      builder["readConcern"] = read_concern if read_concern
    end
    # Retry / follow-up commit: keep j and wtimeout, set w to majority.
    # see: transactions spec, majority write concern when retrying commitTransaction
    if session.majority_commit_wc? && command.is_a?(Commands::CommitTransaction)
      raw = body["writeConcern"]?
      write_concern = raw.is_a?(BSON) ? WriteConcern.from_bson(raw) : WriteConcern.new
      write_concern.w = "majority"
      write_concern.w_timeout ||= 10_000_i64
      old = body
      body = BSON.build do |builder|
        old.each { |key, value, code|
          next if key == "writeConcern"
          if value.is_a?(BSON) && code.array?
            builder.append_array(key, value)
          else
            builder[key] = value
          end
        }
        builder["writeConcern"] = write_concern
      end
    end
    body
  end

  # Versioned API fields. One append. Applied after retryable-write extras.
  private def apply_server_api(body : BSON) : BSON
    api = @options.server_api
    return body unless api

    body.append do |builder|
      builder["apiVersion"] = api.version
      builder["apiStrict"] = api.strict.as(Bool) unless api.strict.nil?
      builder["apiDeprecationErrors"] = api.deprecation_errors.as(Bool) unless api.deprecation_errors.nil?
    end
    body
  end

  private def keeps_implicit_session?(result) : Bool
    case result
    when Commands::Common::QueryResult
      result.cursor.id != 0
    when Commands::GetMore::Result
      result.cursor.id != 0
    when Commands::BulkWrite::Result
      if id = result.cursor.try(&.id)
        id != 0
      else
        false
      end
    when Cursor
      true
    when BSON
      if id = bson_cursor_id(result)
        id != 0
      else
        false
      end
    else
      false
    end
  end

  private def cursor_id_of(result) : Int64?
    case result
    when Commands::Common::QueryResult
      result.cursor.id
    when Commands::GetMore::Result
      result.cursor.id
    when Commands::BulkWrite::Result
      result.cursor.try(&.id)
    when BSON
      bson_cursor_id(result)
    else
      nil
    end
  end

  # runCommand returns the raw reply. A cursor id in that document must pin
  # the load-balanced socket the same way Find/Aggregate QueryResult does.
  private def bson_cursor_id(bson : BSON) : Int64?
    cursor = bson["cursor"]?
    return nil unless cursor.is_a?(BSON)
    id = cursor["id"]?
    case id
    when Int64
      id
    when Int32
      id.to_i64
    else
      nil
    end
  end
end
