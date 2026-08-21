class Mongo::Client
  # See: https://github.com/mongodb/specifications/blob/master/source/retryable-writes/retryable-writes.rst#executing-retryable-write-commands
  private def execute_retryable_write(
    command,
    session : Session::ClientSession,
    read_preference : ReadPreference,
    server_description : SDAM::ServerDescription? = nil,
    operation_id : Int64? = nil,
    end_implicit_session : Bool = true,
    provided_connection : Mongo::Connection? = nil,
    deadline : Mongo::Deadline? = nil,
    **args,
  )
    provided_server = server_description
    server_description = live_retryable_write_server(
      provided_server || session.server_description,
      command,
      args,
      read_preference,
      deadline
    )

    # Unknown is temporary. Handshake rediscovers. Standalone has no retryable writes.
    if !server_description.type.unknown? &&
       (!topology.supports_sessions? || !server_description.supports_retryable_writes?) &&
       !session.is_transaction?
      connection, owns = checkout_for_command(server_description, session, provided_connection, deadline)
      session.pin(server_description)
      return execute_command(command, session, read_preference, server_description, connection, operation_id, end_implicit_session, deadline, owns, **args)
    end

    session.increment_txn_number unless session.is_transaction?

    attempt = 0
    allowed_retries = 1
    original_error : Mongo::Error? = nil

    loop do
      begin
        preferred = provided_server || session.server_description
        server_description = live_retryable_write_server(preferred, command, args, read_preference, deadline)
        if server_description.type.unknown?
          # Handshake rediscovers. Do not treat Unknown as "retryable writes off".
        elsif !topology.supports_sessions? || !server_description.supports_retryable_writes?
          raise original_error if original_error
          raise Mongo::Error.new("Sessions or retryable writes not supported")
        end

        connection, owns = checkout_for_command(server_description, session, provided_connection, deadline)
        session.pin(server_description)
        overload_retry = original_error.try(&.retryable_overload?) || false
        if command.is_a?(Commands::CommitTransaction)
          session.majority_commit_wc = (attempt > 0 || !!session.transitions_from.try(&.committed?)) && !overload_retry
        end
        return execute_command(command, session, read_preference, server_description, connection, operation_id, end_implicit_session, deadline, owns, **args) { |body|
          apply_retryable_write_body(body, session)
        }
      rescue error : Mongo::Error
        error.add_retryable_label(server_description.max_wire_version)
        error.add_unknown_transaction_label if error.retryable_write?

        if error.is_a?(Mongo::Error::Command) && error.code == 20 && error.message.try &.starts_with? "Transaction numbers"
          raise error
        end

        overload = error.retryable_overload?
        retryable = error.retryable_write? || error.is_a?(Error::PoolCleared) || overload
        unless retryable
          raise error
        end

        if overload
          allowed_retries = @options.max_adaptive_retries
        end

        attempt += 1
        if d = deadline
          if !d.infinite? && d.expired?
            raise Mongo::Error::Timeout.new("retryable write exceeded timeoutMS", cause: error)
          end
        elsif attempt > allowed_retries
          raise error
        end

        original_error = error
        session.unpin if error.transient_transaction? || error.unknown_transaction?
        apply_overload_backoff(attempt, error) if overload
      rescue error : Mongo::Client::NetworkError
        wrapped = Error::Network.new(error)
        wrapped.add_retryable_label(server_description.max_wire_version)
        original_error = wrapped
        attempt += 1
        if d = deadline
          raise Mongo::Error::Timeout.new("retryable write exceeded timeoutMS", cause: wrapped) if !d.infinite? && d.expired?
        elsif attempt > allowed_retries
          raise wrapped
        end
      end
    end
  end

  # Prefer a live copy of the pinned server. After closeConnection that
  # address is Unknown. Handshake on get_connection rediscovers it. Waiting
  # only on the monitor can miss that (pool-cleared-error).
  private def live_retryable_write_server(
    preferred : SDAM::ServerDescription?,
    command,
    args,
    read_preference : ReadPreference,
    deadline : Mongo::Deadline? = nil,
  ) : SDAM::ServerDescription
    if preferred
      live = topology.servers.find { |s| s.address == preferred.address }
      if live && !live.type.unknown? && live.supports_retryable_writes?
        return live
      end
      if live && live.type.unknown?
        return live
      end
    end
    # Waiters after PoolCleared have no pin. Handshake an Unknown member only
    # when no writable server is already known.
    writable = false
    unknown = nil.as(SDAM::ServerDescription?)
    topology.servers.each do |server|
      if server.type.rs_primary? || server.type.mongos? || server.type.standalone? || server.type.load_balancer?
        writable = true
        break
      end
      if unknown.nil? && server.type.unknown?
        unknown = server
      end
    end
    if !writable
      if found = unknown
        return found
      end
    end
    server_selection(command, args, read_preference, deadline)
  end

  private def apply_retryable_write_body(body, session)
    # Same txnNumber as the first attempt, even when the topology is Unknown.
    body["txnNumber"] = session.txn_number unless session.is_transaction?
    body
  end

  # Commands that are not retryable reads/writes still retry on overload and pool clear.
  private def execute_once_or_overload_retry(
    command,
    session : Session::ClientSession,
    read_preference : ReadPreference,
    server_description : SDAM::ServerDescription? = nil,
    operation_id : Int64? = nil,
    end_implicit_session : Bool = true,
    provided_connection : Mongo::Connection? = nil,
    deadline : Mongo::Deadline? = nil,
    **args,
  )
    provided_server = server_description
    attempt = 0
    allowed_retries = 0
    original_error : Mongo::Error? = nil

    loop do
      begin
        selected = provided_server || session.server_description || server_selection(command, args, read_preference, deadline)

        if session.options.snapshot && selected.max_wire_version < 13
          raise Error::Client.new("Snapshot reads require MongoDB 5.0 or later")
        end

        connection, owns = checkout_for_command(selected, session, provided_connection, deadline)
        session.pin(selected)
        return execute_command(
          command,
          session,
          read_preference,
          selected,
          connection,
          operation_id,
          end_implicit_session,
          deadline,
          owns,
          **args
        )
      rescue error : Mongo::Error
        overload = error.retryable_overload?
        pool_cleared = error.is_a?(Error::PoolCleared)
        unless overload || pool_cleared
          raise error
        end

        # runCommand retries on overload only when both retry flags are on.
        writes_on = @options.retry_writes != false
        reads_on = @options.retry_reads != false
        if overload && !(writes_on && reads_on)
          raise error
        end

        allowed_retries = overload ? @options.max_adaptive_retries : 1
        attempt += 1
        if d = deadline
          if !d.infinite? && d.expired?
            raise Mongo::Error::Timeout.new("retryable write exceeded timeoutMS", cause: error)
          end
        elsif attempt > allowed_retries
          raise error
        end
        original_error = error
        apply_overload_backoff(attempt, error) if overload
      end
    end
  end

  private def apply_overload_backoff(attempt : Int32, error : Mongo::Error) : Nil
    base = 100.0
    if error.is_a?(Error::Command) && (ms = error.base_backoff_ms) && ms > 0
      base = ms.to_f
    end
    delay_ms = Mongo::Backoff.jitter * Math.min(10_000.0, base * (2 ** attempt))
    sleep delay_ms.milliseconds if delay_ms > 0
  end
end
