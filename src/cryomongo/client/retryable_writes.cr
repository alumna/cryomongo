class Mongo::Client
  # See: https://github.com/mongodb/specifications/blob/master/source/retryable-writes/retryable-writes.rst#executing-retryable-write-commands
  private def execute_retryable_write(
    command,
    session : Session::ClientSession,
    read_preference : ReadPreference,
    server_description : SDAM::ServerDescription? = nil,
    operation_id : Int64? = nil,
    end_implicit_session : Bool = true,
    **args,
  )
    provided_server = server_description
    server_description ||= server_selection(command, args, read_preference)

    if !topology.supports_sessions? || !server_description.supports_retryable_writes?
      connection = get_connection(server_description)
      session.pin(server_description)
      return execute_command(command, session, read_preference, server_description, connection, operation_id, end_implicit_session, **args)
    end

    session.increment_txn_number unless session.is_transaction?

    attempt = 0
    allowed_retries = 1
    original_error : Mongo::Error? = nil

    loop do
      begin
        server_description = provided_server || session.server_description || server_selection(command, args, read_preference)
        if !topology.supports_sessions? || !server_description.supports_retryable_writes?
          raise original_error if original_error
          raise Mongo::Error.new("Sessions or retryable writes not supported")
        end

        connection = get_connection(server_description)
        session.pin(server_description)
        overload_retry = original_error.try(&.retryable_overload?) || false
        return execute_command(command, session, read_preference, server_description, connection, operation_id, end_implicit_session, **args) { |body|
          apply_retryable_write_body(body, command, session, attempt, overload: overload_retry)
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
        if attempt > allowed_retries
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
        raise wrapped if attempt > allowed_retries
      end
    end
  end

  private def apply_retryable_write_body(body, command, session, attempt, *, overload = false)
    if topology.supports_sessions?
      body["txnNumber"] = session.txn_number unless session.is_transaction?
    end

    # Majority WC is for a commit retry after an unknown result. An overload
    # error means the server did not run the commit, so keep the original WC.
    # see: https://github.com/mongodb/specifications/blob/master/source/transactions/transactions.rst#majority-write-concern-is-used-when-retrying-committransaction
    already_committed = command.is_a?(Commands::CommitTransaction) && session.transitions_from.try(&.committed?)
    unknown_commit_retry = command.is_a?(Commands::CommitTransaction) && attempt > 0 && !overload
    if already_committed || unknown_commit_retry
      write_concern = body["writeConcern"]?
      write_concern = write_concern ? WriteConcern.from_bson(write_concern.as(BSON)) : WriteConcern.new
      write_concern.w = "majority"
      write_concern.w_timeout ||= 10_000
      body = body.copy_with({writeConcern: write_concern})
    end

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
    **args,
  )
    provided_server = server_description
    attempt = 0
    allowed_retries = 0
    original_error : Mongo::Error? = nil

    loop do
      begin
        selected = provided_server || session.server_description || server_selection(command, args, read_preference)

        if session.options.snapshot && selected.max_wire_version < 13
          raise Error::Client.new("Snapshot reads require MongoDB 5.0 or later")
        end

        connection = get_connection(selected)
        session.pin(selected)
        return execute_command(
          command,
          session,
          read_preference,
          selected,
          connection,
          operation_id,
          end_implicit_session,
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
        if attempt > allowed_retries
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
