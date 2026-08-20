class Mongo::Client
  # See: https://github.com/mongodb/specifications/blob/master/source/retryable-reads/retryable-reads.rst#implementing-retryable-reads
  private def execute_retryable_read(
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
    # getMore must stay on the originating server. Keep a caller pin on retry.
    provided_server = server_description
    server_description ||= server_selection(command, args, read_preference, deadline)

    if !topology.supports_sessions? || !server_description.supports_retryable_reads?
      connection, owns = checkout_for_command(server_description, session, provided_connection, deadline)
      session.pin(server_description)
      return execute_command(command, session, read_preference, server_description, connection, operation_id, end_implicit_session, deadline, owns, **args)
    end

    attempt = 0
    allowed_retries = 1
    original_error : Mongo::Error? = nil

    loop do
      begin
        server_description = provided_server || session.server_description || server_selection(command, args, read_preference, deadline)
        # TopologyType Single returns an Unknown server immediately. Connecting
        # runs hello and rediscovers. Do not abort the retry just because
        # sessions dropped while the only server was Unknown.
        if original_error && server_description.type.unknown?
          # Handshake on get_connection rediscovers standalone.
        elsif !topology.supports_sessions? || !server_description.supports_retryable_reads?
          raise original_error if original_error
          raise Mongo::Error.new("Sessions or retryable reads not supported")
        end

        connection, owns = checkout_for_command(server_description, session, provided_connection, deadline)
        session.pin(server_description)
        return execute_command(command, session, read_preference, server_description, connection, operation_id, end_implicit_session, deadline, owns, **args)
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
