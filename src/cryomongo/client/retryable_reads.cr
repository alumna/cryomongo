class Mongo::Client
  # See: https://github.com/mongodb/specifications/blob/master/source/retryable-reads/retryable-reads.rst#implementing-retryable-reads
  private def execute_retryable_read(
    command,
    session : Session::ClientSession,
    read_preference : ReadPreference,
    server_description : SDAM::ServerDescription? = nil,
    operation_id : Int64? = nil,
    end_implicit_session : Bool = true,
    **args,
  )
    # getMore must stay on the originating server. Keep a caller pin on retry.
    provided_server = server_description
    server_description ||= server_selection(command, args, read_preference)

    if !topology.supports_sessions? || !server_description.supports_retryable_reads?
      connection = get_connection(server_description)
      session.pin(server_description)
      return execute_command(command, session, read_preference, server_description, connection, operation_id, end_implicit_session, **args)
    end

    attempt = 0
    allowed_retries = 1
    original_error : Mongo::Error? = nil

    loop do
      begin
        server_description = provided_server || session.server_description || server_selection(command, args, read_preference)
        if !topology.supports_sessions? || !server_description.supports_retryable_reads?
          raise original_error if original_error
          raise Mongo::Error.new("Sessions or retryable reads not supported")
        end

        connection = get_connection(server_description)
        session.pin(server_description)
        return execute_command(command, session, read_preference, server_description, connection, operation_id, end_implicit_session, **args)
      rescue error : Mongo::Error
        # execute_command wraps IO errors as Error::Network before raise.
        # Catch Mongo::Error first, same as execute_retryable_write.
        if error.retryable_read? || error.retryable_overload? || error.is_a?(Error::PoolCleared)
          original_error = error
        else
          raise error
        end
      rescue error : NetworkError
        original_error = Error::Network.new(error)
      end

      overload = original_error.try(&.retryable_overload?) || false
      if overload
        allowed_retries = @options.max_adaptive_retries
      end

      attempt += 1
      if attempt > allowed_retries
        raise original_error if original_error
        raise Mongo::Error.new("Unknown error during retryable read")
      end

      apply_overload_backoff(attempt, original_error) if overload && original_error
    end
  end
end
