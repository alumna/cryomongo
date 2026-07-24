class Mongo::Client
  # See: https://github.com/mongodb/specifications/blob/master/source/retryable-writes/retryable-writes.rst#executing-retryable-write-commands
  private def execute_retryable_write(
    command,
    session : Session::ClientSession,
    read_preference : ReadPreference,
    server_description : SDAM::ServerDescription? = nil,
    operation_id : Int64? = nil,
    **args,
  )
    server_description ||= server_selection(command, args, read_preference)
    connection = get_connection(server_description)
    session.pin(server_description)

    if !topology.supports_sessions? || !server_description.supports_retryable_writes?
      return execute_command(command, session, read_preference, server_description, connection, operation_id, **args)
    end

    session.increment_txn_number unless session.is_transaction?

    begin
      return execute_command(command, session, read_preference, server_description, connection, operation_id, **args) { |body|
        if topology.supports_sessions?
          # txnNumber has been added to the body earlier if this is a transaction
          body["txnNumber"] = session.txn_number unless session.is_transaction?
        end

        # see: https://github.com/mongodb/specifications/blob/master/source/transactions/transactions.rst#committransaction
        # see: https://github.com/mongodb/specifications/blob/master/source/transactions/transactions.rst#majority-write-concern-is-used-when-retrying-committransaction
        if command.is_a?(Commands::CommitTransaction) && session.transitions_from.try &.committed?
          write_concern = body["writeConcern"]?
          write_concern = write_concern ? WriteConcern.from_bson(write_concern.as(BSON)) : WriteConcern.new
          write_concern.w = "majority"
          write_concern.w_timeout ||= 10_000
          body = body.copy_with({writeConcern: write_concern})
        end

        body
      }
    rescue error : Mongo::Error
      error.add_retryable_label(server_description.max_wire_version)
      error.add_unknown_transaction_label if error.retryable_write?

      if error.is_a?(Mongo::Error::Command) && (error.code == 20 || error.max_time_ms_expired?)
        raise error
      elsif error.retryable_write?
        original_error = error
      else
        raise error
      end
    end

    begin
      server_description = session.server_description || server_selection(command, args, read_preference)
      connection = get_connection(server_description)
      session.pin(server_description)
    rescue
      raise original_error if original_error
      raise Mongo::Error.new("Unknown error during retryable write")
    end

    if !topology.supports_sessions? || !server_description.supports_retryable_writes?
      raise original_error if original_error
      raise Mongo::Error.new("Sessions or retryable writes not supported")
    end

    begin
      execute_command(command, session, read_preference, server_description, connection, operation_id, **args) { |body|
        if topology.supports_sessions?
          # txnNumber has been added to the body earlier if this is a transaction
          body["txnNumber"] = session.txn_number unless session.is_transaction?
        end

        # see: https://github.com/mongodb/specifications/blob/master/source/transactions/transactions.rst#committransaction
        # see: https://github.com/mongodb/specifications/blob/master/source/transactions/transactions.rst#majority-write-concern-is-used-when-retrying-committransaction
        if command.is_a?(Commands::CommitTransaction)
          write_concern = body["writeConcern"]?
          write_concern = write_concern ? WriteConcern.from_bson(write_concern.as(BSON)) : WriteConcern.new
          write_concern.w = "majority"
          write_concern.w_timeout ||= 10_000
          body = body.copy_with({writeConcern: write_concern})
        end

        body
      }
    rescue error : Mongo::Error
      error.add_retryable_label(server_description.max_wire_version)
      error.add_unknown_transaction_label if error.retryable_write?

      raise error
    end
  end
end
