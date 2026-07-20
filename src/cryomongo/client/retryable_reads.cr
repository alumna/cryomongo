class Mongo::Client
  # See: https://github.com/mongodb/specifications/blob/master/source/retryable-reads/retryable-reads.rst#implementing-retryable-reads
  private def execute_retryable_read(
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

    if !topology.supports_sessions? || !server_description.supports_retryable_reads?
      return execute_command(command, session, read_preference, server_description, connection, operation_id, **args)
    end

    begin
      return execute_command(command, session, read_preference, server_description, connection, operation_id, **args)
    rescue error : NetworkError
      error = Error::Network.new(error)
      original_error = error
    rescue error : Mongo::Error::Network
      original_error = error
    rescue error : Mongo::Error::Command
      if error.retryable_read?
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
      raise Mongo::Error.new("Unknown error during retryable read")
    end

    if !topology.supports_sessions? || !server_description.supports_retryable_reads?
      raise original_error if original_error
      raise Mongo::Error.new("Sessions or retryable reads not supported")
    end

    begin
      execute_command(command, session, read_preference, server_description, connection, operation_id, **args)
    rescue error : Mongo::Error
      raise error
    end
  end
end
