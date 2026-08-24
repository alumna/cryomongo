class Mongo::Client
  # Spec command logs. Handshake and monitor hello do not call execute_command.
  protected def want_command_logs? : Bool
    Logging.want?(@log_sink, Logging::Component::Command, Logging::Severity::Debug)
  end

  private def want_topology_logs? : Bool
    Logging.want?(@log_sink, Logging::Component::Topology, Logging::Severity::Debug)
  end

  private def want_connection_logs? : Bool
    Logging.want?(@log_sink, Logging::Component::Connection, Logging::Severity::Debug)
  end

  # Constructor SDAM events are queued until UTF subscribes (start_sdam_monitoring).
  # Heartbeats use log_heartbeat_* so they are not logged twice.
  private def log_sdam(event : Monitoring::SDAM::Event) : Nil
    case event
    when Monitoring::SDAM::TopologyOpeningEvent
      return unless want_topology_logs?
      data = log_topology_id
      data["message"] = Logging.any("Starting topology monitoring")
      Logging.emit(@log_sink, Logging::Component::Topology, Logging::Severity::Debug, data,
        "Starting monitoring for topology with ID #{event.topology_id}")
    when Monitoring::SDAM::TopologyClosedEvent
      return unless want_topology_logs?
      data = log_topology_id
      data["message"] = Logging.any("Stopped topology monitoring")
      Logging.emit(@log_sink, Logging::Component::Topology, Logging::Severity::Debug, data,
        "Stopped monitoring for topology with ID #{event.topology_id}")
    when Monitoring::SDAM::ServerOpeningEvent
      return unless want_topology_logs?
      data = log_server_fields(event.address)
      data["message"] = Logging.any("Starting server monitoring")
      Logging.emit(@log_sink, Logging::Component::Topology, Logging::Severity::Debug, data,
        "Starting monitoring for server #{event.address} in topology with ID #{event.topology_id}")
    when Monitoring::SDAM::ServerClosedEvent
      return unless want_topology_logs?
      data = log_server_fields(event.address)
      data["message"] = Logging.any("Stopped server monitoring")
      Logging.emit(@log_sink, Logging::Component::Topology, Logging::Severity::Debug, data,
        "Stopped monitoring for server #{event.address} in topology with ID #{event.topology_id}")
    when Monitoring::SDAM::TopologyDescriptionChangedEvent
      return unless want_topology_logs?
      data = log_topology_id
      data["message"] = Logging.any("Topology description changed")
      data["previousDescription"] = Logging.any(event.previous_description.to_s)
      data["newDescription"] = Logging.any(event.new_description.to_s)
      Logging.emit(@log_sink, Logging::Component::Topology, Logging::Severity::Debug, data,
        "Description changed for topology with ID #{event.topology_id}")
    else
      # Heartbeats use log_heartbeat_*. ServerDescriptionChanged has no log message.
    end
  end

  private def log_heartbeat_started(address : String, awaited : Bool, driver_connection_id : Int64?, server_connection_id : Int64?) : Nil
    return unless want_topology_logs?
    data = log_server_fields(address)
    data["message"] = Logging.any("Server heartbeat started")
    data["awaited"] = Logging.any(awaited)
    Logging.put(data, "driverConnectionId", driver_connection_id)
    Logging.put(data, "serverConnectionId", server_connection_id)
    Logging.emit(@log_sink, Logging::Component::Topology, Logging::Severity::Debug, data,
      "Heartbeat started for #{address}")
  end

  private def log_heartbeat_succeeded(address : String, duration : Time::Span, reply : BSON, awaited : Bool, driver_connection_id : Int64?, server_connection_id : Int64?) : Nil
    return unless want_topology_logs?
    data = log_server_fields(address)
    data["message"] = Logging.any("Server heartbeat succeeded")
    data["awaited"] = Logging.any(awaited)
    data["durationMS"] = Logging.duration_ms(duration)
    data["reply"] = Logging.any(Logging.document_json(reply))
    Logging.put(data, "driverConnectionId", driver_connection_id)
    Logging.put(data, "serverConnectionId", server_connection_id)
    Logging.emit(@log_sink, Logging::Component::Topology, Logging::Severity::Debug, data,
      "Heartbeat succeeded for #{address}")
  end

  private def log_heartbeat_failed(address : String, duration : Time::Span, failure : Exception, awaited : Bool, driver_connection_id : Int64?, server_connection_id : Int64?) : Nil
    return unless want_topology_logs?
    data = log_server_fields(address)
    data["message"] = Logging.any("Server heartbeat failed")
    data["awaited"] = Logging.any(awaited)
    data["durationMS"] = Logging.duration_ms(duration)
    data["failure"] = Logging.any(failure.message || failure.class.name)
    Logging.put(data, "driverConnectionId", driver_connection_id)
    Logging.put(data, "serverConnectionId", server_connection_id)
    Logging.emit(@log_sink, Logging::Component::Topology, Logging::Severity::Debug, data,
      "Heartbeat failed for #{address}: #{failure}")
  end

  private def log_cmap(event : Monitoring::CMAP::Event) : Nil
    return unless want_connection_logs?
    data = log_host_port(event.address)
    text = ""
    case event
    when Monitoring::CMAP::PoolCreatedEvent
      data["message"] = Logging.any("Connection pool created")
      event.options.each { |key, value| data[key] = Logging.any(value) }
      text = "Connection pool created for #{event.address}"
    when Monitoring::CMAP::PoolReadyEvent
      data["message"] = Logging.any("Connection pool ready")
      text = "Connection pool ready for #{event.address}"
    when Monitoring::CMAP::PoolClearedEvent
      data["message"] = Logging.any("Connection pool cleared")
      Logging.put(data, "serviceId", event.service_id.try(&.to_s))
      text = "Connection pool for #{event.address} cleared"
    when Monitoring::CMAP::PoolClosedEvent
      data["message"] = Logging.any("Connection pool closed")
      text = "Connection pool closed for #{event.address}"
    when Monitoring::CMAP::ConnectionCreatedEvent
      data["message"] = Logging.any("Connection created")
      data["driverConnectionId"] = Logging.any(event.connection_id)
      text = "Connection created: address=#{event.address}, driver-generated ID=#{event.connection_id}"
    when Monitoring::CMAP::ConnectionReadyEvent
      data["message"] = Logging.any("Connection ready")
      data["driverConnectionId"] = Logging.any(event.connection_id)
      data["durationMS"] = Logging.duration_ms(event.duration)
      text = "Connection ready: address=#{event.address}, driver-generated ID=#{event.connection_id}"
    when Monitoring::CMAP::ConnectionClosedEvent
      data["message"] = Logging.any("Connection closed")
      data["driverConnectionId"] = Logging.any(event.connection_id)
      data["reason"] = Logging.any(Logging.closed_reason(event.reason))
      if err = event.error
        data["error"] = Logging.any(err.message || err.class.name)
      end
      text = "Connection closed: address=#{event.address}, driver-generated ID=#{event.connection_id}"
    when Monitoring::CMAP::ConnectionCheckOutStartedEvent
      data["message"] = Logging.any("Connection checkout started")
      text = "Checkout started for connection to #{event.address}"
    when Monitoring::CMAP::ConnectionCheckedOutEvent
      data["message"] = Logging.any("Connection checked out")
      data["driverConnectionId"] = Logging.any(event.connection_id)
      data["durationMS"] = Logging.duration_ms(event.duration)
      text = "Connection checked out: address=#{event.address}, driver-generated ID=#{event.connection_id}"
    when Monitoring::CMAP::ConnectionCheckedInEvent
      data["message"] = Logging.any("Connection checked in")
      data["driverConnectionId"] = Logging.any(event.connection_id)
      text = "Connection checked in: address=#{event.address}, driver-generated ID=#{event.connection_id}"
    when Monitoring::CMAP::ConnectionCheckOutFailedEvent
      data["message"] = Logging.any("Connection checkout failed")
      data["reason"] = Logging.any(Logging.checkout_failed_reason(event.reason))
      data["durationMS"] = Logging.duration_ms(event.duration)
      if err = event.error
        data["error"] = Logging.any(err.message || err.class.name)
      end
      text = "Checkout failed for connection to #{event.address}"
    else
      return
    end
    Logging.emit(@log_sink, Logging::Component::Connection, Logging::Severity::Debug, data, text)
  end

  protected def log_command_started(
    command_name : String,
    database_name : String,
    request_id : Int64,
    operation_id : Int64?,
    address : String,
    command : BSON,
    driver_connection_id : Int64,
    server_connection_id : Int64?,
    service_id : BSON::ObjectId?,
  ) : Nil
    return unless want_command_logs?
    data = command_log_fields(command_name, database_name, request_id, operation_id, address, driver_connection_id, server_connection_id, service_id)
    data["message"] = Logging.any("Command started")
    data["command"] = Logging.any(Logging.document_json(command))
    Logging.emit(@log_sink, Logging::Component::Command, Logging::Severity::Debug, data,
      "Command \"#{command_name}\" started on database \"#{database_name}\"")
  end

  protected def log_command_succeeded(
    command_name : String,
    database_name : String,
    request_id : Int64,
    operation_id : Int64?,
    address : String,
    duration : Time::Span,
    reply : BSON,
    driver_connection_id : Int64,
    server_connection_id : Int64?,
    service_id : BSON::ObjectId?,
  ) : Nil
    return unless want_command_logs?
    data = command_log_fields(command_name, database_name, request_id, operation_id, address, driver_connection_id, server_connection_id, service_id)
    data["message"] = Logging.any("Command succeeded")
    data["durationMS"] = Logging.duration_ms(duration)
    data["reply"] = Logging.any(Logging.document_json(reply))
    Logging.emit(@log_sink, Logging::Component::Command, Logging::Severity::Debug, data,
      "Command \"#{command_name}\" succeeded on database \"#{database_name}\"")
  end

  protected def log_command_failed(
    command_name : String,
    database_name : String,
    request_id : Int64,
    operation_id : Int64?,
    address : String,
    duration : Time::Span,
    failure : Exception,
    driver_connection_id : Int64,
    server_connection_id : Int64?,
    service_id : BSON::ObjectId?,
  ) : Nil
    return unless want_command_logs?
    data = command_log_fields(command_name, database_name, request_id, operation_id, address, driver_connection_id, server_connection_id, service_id)
    data["message"] = Logging.any("Command failed")
    data["durationMS"] = Logging.duration_ms(duration)
    data["failure"] = Logging.any(failure.message || failure.class.name)
    Logging.emit(@log_sink, Logging::Component::Command, Logging::Severity::Debug, data,
      "Command \"#{command_name}\" failed on database \"#{database_name}\"")
  end

  private def command_log_fields(
    command_name : String,
    database_name : String,
    request_id : Int64,
    operation_id : Int64?,
    address : String,
    driver_connection_id : Int64,
    server_connection_id : Int64?,
    service_id : BSON::ObjectId?,
  ) : Hash(String, JSON::Any)
    data = log_host_port(address)
    data["commandName"] = Logging.any(command_name)
    data["databaseName"] = Logging.any(database_name)
    data["requestId"] = Logging.any(request_id)
    Logging.put(data, "operationId", operation_id)
    data["driverConnectionId"] = Logging.any(driver_connection_id)
    Logging.put(data, "serverConnectionId", server_connection_id)
    Logging.put(data, "serviceId", service_id.try(&.to_s))
    data
  end

  private def log_topology_id : Hash(String, JSON::Any)
    data = {} of String => JSON::Any
    data["topologyId"] = Logging.any(object_id)
    data
  end

  private def log_server_fields(address : String) : Hash(String, JSON::Any)
    data = log_topology_id
    host, port = Logging.host_port(address)
    data["serverHost"] = Logging.any(host)
    Logging.put(data, "serverPort", port)
    data
  end

  private def log_host_port(address : String) : Hash(String, JSON::Any)
    data = {} of String => JSON::Any
    host, port = Logging.host_port(address)
    data["serverHost"] = Logging.any(host)
    Logging.put(data, "serverPort", port)
    data
  end
end
