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
    # endSessions during pool close must not check out from the pool.
    owns_session = session.nil?
    if session.nil?
      session = if command.is_a?(Commands::EndSessions)
                  Session::ClientSession.new(self, pooled: false)
                else
                  Session::ClientSession.new(self)
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
            deadline: deadline || Mongo::Deadline.from_options(@options),
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
          deadline: deadline || Mongo::Deadline.from_options(@options),
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

    # Session could be pinned to a specific mongos - if so use the same server description
    server_description ||= session.server_description

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
    deadline.try(&.check!)
    remaining = if (d = deadline) && !d.infinite?
                  d.remaining
                else
                  nil
                end
    connection.apply_timeout(remaining || @options.socket_timeout)

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

    # Apply session rules, then retry extras, then Server API.
    session.mark_used
    body = apply_session_fields(body, session, unacknowledged, command, server_description, **args)
    body = (yield body) || body
    body = apply_server_api(body)
    body = apply_csot_max_time(body, command, deadline, server_description)

    # Create the OP_MSG message to send.
    op_msg = Messages::OpMsg.new(body, flag_bits: flag_bits)
    sequences.try &.each { |key, documents|
      op_msg.sequence(key.to_s, contents: documents)
    }

    # Command monitoring related variables.
    duration_start = Time.instant
    request_id = uninitialized Int64
    command_name = command.name
    address = connection.server_description.address

    # Send the command.
    connection.send(op_msg, command) { |message|
      # Monitor by sending a CommandStartedEvent
      if @commands_observable.has_subscribers?
        request_id = message.header.request_id.to_i64

        @commands_observable.broadcast(Monitoring::Commands::CommandStartedEvent.new(
          command_name: command_name,
          request_id: request_id,
          operation_id: operation_id,
          address: address,
          command: op_msg.safe_payload(command),
          database_name: op_msg.body["$db"].as(String)
        ))
      end
    }

    # If the write is unacknowledged - early return.
    if unacknowledged
      if @commands_observable.has_subscribers?
        @commands_observable.broadcast(Monitoring::Commands::CommandSucceededEvent.new(
          command_name: command_name,
          request_id: request_id,
          operation_id: operation_id,
          address: address,
          duration: duration_start.elapsed,
          reply: BSON.new({ok: 1})
        ))
      end

      return nil
    end

    # Receive the server sent OP_MSG.
    op_msg = connection.receive do |message|
      op_msg = message.contents.as(Messages::OpMsg)
      duration = duration_start.elapsed

      # Monitor.
      if @commands_observable.has_subscribers?
        if error = op_msg.error?
          @commands_observable.broadcast(Monitoring::Commands::CommandFailedEvent.new(
            command_name: command_name,
            request_id: message.header.response_to.to_i64,
            operation_id: operation_id,
            address: address,
            duration: duration,
            reply: op_msg.safe_payload(command),
            failure: Monitoring::Redact.failure(command_name, error, op_msg.body)
          ))
        else
          @commands_observable.broadcast(Monitoring::Commands::CommandSucceededEvent.new(
            command_name: command_name,
            request_id: message.header.response_to.to_i64,
            operation_id: operation_id,
            address: address,
            duration: duration,
            reply: op_msg.safe_payload(command)
          ))
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
    if error = op_msg.error?
      raise wrap_csot_timeout(error, deadline)
    end

    # Parse and return the body as a custom Result type.
    result = command.result(op_msg.body)
    session.last_operation_server = server_description
    if @options.load_balanced && owns_connection
      if session.is_transaction? && (session.transaction_state.starting? || session.transaction_state.in_progress?)
        session.pin_connection(connection)
        owns_connection = false
      elsif (cid = cursor_id_of(result)) && cid != 0
        session.pending_cursor_connection = connection
        owns_connection = false
      end
    end
    result
  rescue error
    if error.is_a?(NetworkError)
      Mongo::Log.error(exception: error) { "Network error" } unless server_description
      # see: https://github.com/mongodb/specifications/blob/master/source/server-discovery-and-monitoring/server-monitoring.rst#network-or-command-error-during-server-check
      server_description.try { |desc|
        Mongo::Log.error(exception: error) { "I/O error with server address: #{desc.address}" }
        description = SDAM::ServerDescription.new(desc.address)
        description.error = error.message
        description.last_update_time = desc.last_update_time
        topology.update(desc, description)
        close_connection_pool(desc)
        @monitors.find(&.server_description.address.== desc.address).try &.request_immediate_scan
      }
      session.try &.dirty = true
      error = Error::Network.new(error)
      if (d = deadline) && !d.infinite?
        cause = error.cause
        if d.expired? || cause.is_a?(IO::TimeoutError)
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
        apply_state_change_error(server_description, error)
      end
    end

    if error.is_a?(Mongo::Error)
      if command.is_a? Commands::CommitTransaction
        error.add_unknown_transaction_label
      else
        error.add_transient_transaction_label
      end

      # Stay pinned after UnknownTransactionCommitResult so commit retries on
      # the same mongos. Unpin only on TransientTransactionError.
      if error.transient_transaction?
        session.try &.unpin
      end
    end

    raise error
  ensure
    release_connection(connection) if connection && owns_connection
    if end_implicit_session && !keeps_implicit_session?(result)
      session.try &.end if session.try(&.implicit?)
    end
  end

  # Mark the server Unknown after a not-master / recovering error, unless the
  # error's topologyVersion is older than the description we already have.
  private def apply_state_change_error(server_description : SDAM::ServerDescription?, error : Mongo::Error::Command) : Nil
    desc = server_description
    return unless desc

    if topology.is_stale_error_topology_version?(desc.topology_version, error.topology_version)
      return
    end

    description = SDAM::ServerDescription.new(desc.address)
    description.min_wire_version = desc.min_wire_version
    description.max_wire_version = desc.max_wire_version
    description.error = error.message
    description.last_update_time = desc.last_update_time
    description.topology_version = error.topology_version
    topology.update(desc, description)
    close_connection_pool(desc) if error.shutdown?
    @monitors.find(&.server_description.address.== desc.address).try &.request_immediate_scan
  end

  # CSOT: remaining timeout minus min RTT. getMore on a non-awaitData cursor
  # must not get maxTimeMS. AwaitData getMore already has maxTimeMS (maxAwaitTimeMS).
  private def apply_csot_max_time(body : BSON, command, deadline : Mongo::Deadline?, server_description : SDAM::ServerDescription) : BSON
    return body unless deadline
    return body if deadline.infinite?

    min_rtt = server_description.min_round_trip_time
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
    server_description : SDAM::ServerDescription,
    **args,
  ) : BSON
    return body unless topology.supports_sessions?

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

    if session.is_transaction? && server_description.supports_retryable_writes?
      if session.transitions_from.try(&.starting?) || session.apply_transaction_read_concern?
        start_transaction = true
      end
      add_txn_fields = true
    end

    unless command.is_a?(Commands::EndSessions) || command.is_a?(Commands::Hello)
      if session.options.snapshot && !has_read_concern
        read_concern = ReadConcern.new(level: "snapshot", at_cluster_time: session.snapshot_time)
      elsif session.is_transaction? && start_transaction && !has_read_concern
        read_concern = session.current_transaction_options.read_concern
      end
      if session.is_transaction? && start_transaction
        session.apply_transaction_read_concern = false
      end
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

    return body unless add_lsid || cluster_time || add_txn_fields || read_concern

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
    when Cursor
      true
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
    else
      nil
    end
  end
end
