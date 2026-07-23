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
    **args,
    &block
  )
    # Create an implicit session
    session ||= Session::ClientSession.new(self)

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
    **args,
  )
    self.command(cmd, write_concern, read_concern, read_preference, server_description, session, operation_id, **args) { |result|
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
    **args,
  )
    # Mix collection/database/client/options read and write concerns considering the precedence rules.
    args = WithWriteConcern.mix_write_concern(command, args, write_concern || @write_concern, session: session)
    args = WithReadConcern.mix_read_concern(command, args, read_concern || @read_concern, session: session)

    # Determines the read preference to apply to the command
    if WithReadPreference.must_use_primary_command?(command, args)
      read_preference = ReadPreference.new(mode: "primary")
    else
      if session.is_transaction?
        read_preference = session.current_transaction_options.read_preference || read_preference || @read_preference || ReadPreference.new(mode: "primary")
      else
        read_preference = read_preference || @read_preference || ReadPreference.new(mode: "primary")
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
        **args
      )
    elsif retryable_command && @options.retry_reads && command.is_a?(Commands::ReadCommand) && command.read_command?
      execute_retryable_read(
        command,
        session,
        read_preference,
        server_description,
        operation_id,
        **args
      )
    else
      # Select a suitable server and retrieve the underlying connection.
      server_description ||= server_selection(command, args, read_preference)

      if session.options.snapshot && server_description.max_wire_version < 13
        raise Error::Client.new("Snapshot reads require MongoDB 5.0 or later")
      end

      connection = get_connection(server_description)
      session.pin(server_description)

      execute_command(
        command,
        session,
        read_preference,
        server_description,
        connection,
        operation_id,
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
    **args,
  )
    execute_command(command, session, read_preference, server_description, connection, operation_id, **args) { }
  end

  private def execute_command(
    command,
    session : Session::ClientSession,
    read_preference : ReadPreference,
    server_description : SDAM::ServerDescription,
    connection : Mongo::Connection,
    operation_id : Int64? = nil,
    **args,
    &
  )
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

    # Apply session rules.
    if topology.supports_sessions?
      if unacknowledged
        # Sessions are not compatible with unacknowledged writes
        raise Mongo::Error.new("Unacknowledged writes are incompatible with sessions.") unless session.implicit?
      end

      body["lsid"] = session.session_id

      if topology.supports_cluster_time?
        cluster_time = gossip_cluster_time(session)
        body["$clusterTime"] = cluster_time if cluster_time
      end

      if session.is_transaction? && server_description.supports_retryable_writes?
        if session.transitions_from.try(&.starting?)
          body["startTransaction"] = true
        end
        body["txnNumber"] = session.txn_number
        body["autocommit"] = false
      end
    end

    body = (yield body) || body

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
      @commands_observable.broadcast(Monitoring::Commands::CommandSucceededEvent.new(
        command_name: command_name,
        request_id: request_id,
        operation_id: operation_id,
        address: address,
        duration: duration_start.elapsed,
        reply: BSON.new({ok: 1})
      ))

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
            request_id: message.header.request_id.to_i64,
            operation_id: operation_id,
            address: address,
            duration: duration,
            reply: op_msg.safe_payload(command),
            failure: error
          ))
        else
          @commands_observable.broadcast(Monitoring::Commands::CommandSucceededEvent.new(
            command_name: command_name,
            request_id: message.header.request_id.to_i64,
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
      @cluster_time = cluster_time if !@cluster_time || @cluster_time.try &.< cluster_time
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
      raise error
    end

    # Parse and return the body as a custom Result type.
    result = command.result(op_msg.body)
    result
  rescue error
    if error.is_a?(NetworkError)
      Mongo::Log.error(exception: error) { "Network error" } unless server_description
      # see: https://github.com/mongodb/specifications/blob/master/source/server-discovery-and-monitoring/server-monitoring.rst#network-or-command-error-during-server-check
      is_timeout = error.is_a?(IO::TimeoutError)
      unless is_timeout
        server_description.try { |desc|
          Mongo::Log.error(exception: error) { "I/O error with server address: #{desc.address}" }
          description = SDAM::ServerDescription.new(desc.address)
          description.error = error.message
          description.last_update_time = desc.last_update_time
          topology.update(desc, description)
          close_connection_pool(desc)
        }
      end
      session.try &.dirty = true
      error = Error::Network.new(error)
    end

    if error.is_a?(Mongo::Error::Command)
      Mongo::Log.error { "Command error: #{error}" }
      # see: https://github.com/mongodb/specifications/blob/master/source/server-discovery-and-monitoring/server-discovery-and-monitoring.rst#not-master-and-node-is-recovering
      if error.state_change?
        server_description.try { |desc|
          description = SDAM::ServerDescription.new(desc.address)
          description.min_wire_version = desc.min_wire_version
          description.max_wire_version = desc.max_wire_version
          description.error = error.message
          description.last_update_time = desc.last_update_time
          topology.update(desc, description)
          close_connection_pool(desc) if error.shutdown?
          @monitors.find(&.server_description.address.== desc.address).try &.request_immediate_scan
        }
      end
    end

    if error.is_a?(Mongo::Error)
      if command.is_a? Commands::CommitTransaction
        error.add_unknown_transaction_label
      else
        error.add_transient_transaction_label
      end

      if error.transient_transaction? || error.unknown_transaction?
        session.try &.unpin
      end
    end

    raise error
  ensure
    release_connection(connection) if connection
    if result.is_a? Cursor
      # Bind the Cursor to the same server for its lifetime.
      result.server_description = server_description
      # Bind the session
      result.session = session
    else
      # End the session if implicit
      session.try &.end if session.try(&.implicit?)
    end
  end
end
