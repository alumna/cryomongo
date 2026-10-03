class Mongo::Client
  private def server_selection(command, args, read_preference : ReadPreference, deadline : Mongo::Deadline? = nil, deprioritized : Array(String)? = nil) : SDAM::ServerDescription
    # See: https://github.com/mongodb/specifications/blob/master/source/server-selection/server-selection.rst#multi-threaded-or-asynchronous-server-selection
    selection_start, selection_timeout, effective = selection_wait_budget(deadline)
    # Crystal is concurrent (and can be parallel). The multi-threaded default is false:
    # keep scanning until the timeout. true = one extra scan, then raise.
    try_once = @options.server_selection_try_once
    waited_once = false

    loop do
      unless topology.compatible
        raise Error::ServerSelection.new topology.compatibility_error
      end

      # Find suitable servers by topology type and operation type.
      # Then pick one at random from those within the latency window.
      suitable_servers = find_suitable_servers(command, args, read_preference, deprioritized)
      selected_server = SDAM::Selector.pick(suitable_servers, @options.local_threshold)
      return selected_server if selected_server

      # Request an immediate topology check, then block until the topology
      # changes or until the server selection timeout has elapsed.
      @monitors.each { |monitor|
        monitor.request_immediate_scan
      }

      # The monitor may have already published. Recheck before sleeping.
      suitable_servers = find_suitable_servers(command, args, read_preference, deprioritized)
      selected_server = SDAM::Selector.pick(suitable_servers, @options.local_threshold)
      return selected_server if selected_server

      if try_once && waited_once
        raise selection_timeout_error(read_preference, effective)
      end

      remaining = selection_timeout - selection_start.elapsed
      if remaining <= Time::Span.zero
        raise selection_timeout_error(read_preference, effective)
      end

      select
      when @topology_update.receive
      when timeout remaining
      end

      waited_once = true

      if selection_start.elapsed >= selection_timeout
        raise selection_timeout_error(read_preference, effective)
      end
    end
  end

  # Live copy of a session pin. Mongos / load balancer only. Unknown is not
  # selectable. The pin object can stay Mongos after SDAM replaced the topology
  # entry with Unknown.
  private def live_selectable_pin?(address : String) : SDAM::ServerDescription?
    topology.servers.each do |server|
      next unless server.address == address
      return server if server.type.mongos? || server.type.load_balancer?
      return nil
    end
    nil
  end

  # DRIVERS-2032: after a handshake or heartbeat network error the pinned
  # mongos is Unknown and the pool is paused. Wait until that address is a
  # mongos again. Do not pick another mongos. Do not handshake Unknown while
  # the session is still pinned. Load-balanced has no monitors and stays
  # LoadBalancer, so return at once.
  private def wait_for_selectable_pin(pin : SDAM::ServerDescription, deadline : Mongo::Deadline? = nil) : SDAM::ServerDescription
    if found = live_selectable_pin?(pin.address)
      return found
    end

    if @options.load_balanced || pin.type.load_balancer?
      topology.servers.each do |server|
        return server if server.address == pin.address
      end
      raise Error::ServerSelection.new("pinned server #{pin.address} is gone")
    end

    selection_start, selection_timeout, effective = selection_wait_budget(deadline)
    try_once = @options.server_selection_try_once
    waited_once = false

    loop do
      unless topology.compatible
        raise Error::ServerSelection.new topology.compatibility_error
      end

      if found = live_selectable_pin?(pin.address)
        return found
      end

      request_scan_for_address(pin.address)

      if found = live_selectable_pin?(pin.address)
        return found
      end

      if try_once && waited_once
        raise pin_selection_timeout_error(pin.address, effective)
      end

      remaining = selection_timeout - selection_start.elapsed
      if remaining <= Time::Span.zero
        raise pin_selection_timeout_error(pin.address, effective)
      end

      select
      when @topology_update.receive
      when timeout remaining
      end

      waited_once = true

      if selection_start.elapsed >= selection_timeout
        raise pin_selection_timeout_error(pin.address, effective)
      end
    end
  end

  # Prefer a live selectable pin. After unpin, use the caller server or a
  # normal selection so commit can move to another mongos (recovery token).
  private def select_with_session_pin(
    provided : SDAM::ServerDescription?,
    session : Session::ClientSession,
    command,
    args,
    read_preference : ReadPreference,
    deadline : Mongo::Deadline? = nil,
    deprioritized : Array(String)? = nil,
  ) : SDAM::ServerDescription
    if pin = session.server_description
      return wait_for_selectable_pin(pin, deadline)
    end
    provided || server_selection(command, args, read_preference, deadline, deprioritized)
  end

  private def request_scan_for_address(address : String) : Nil
    @monitors.each do |monitor|
      if monitor.server_description.address == address
        monitor.request_immediate_scan
        break
      end
    end
  end

  # Use a monotonic clock. Wall time can jump and would shorten or stretch the wait.
  private def selection_wait_budget(deadline : Mongo::Deadline?) : {Time::Instant, Time::Span, Mongo::Deadline?}
    selection_start = Time.instant
    selection_timeout = @options.server_selection_timeout
    effective = deadline || Mongo::Deadline.from_options(@options)
    if effective && !effective.infinite?
      left = effective.remaining
      selection_timeout = left if left < selection_timeout
      # Leftover 0 still tries one pick of a ready server (deadline at
      # first byte). The loop raises if none is ready.
    end
    {selection_start, selection_timeout, effective}
  end

  private def selection_timeout_error(read_preference : ReadPreference, deadline : Mongo::Deadline? = nil)
    msg = "Timeout (#{@options.server_selection_timeout}) reached while trying to select a suitable server with read preference #{read_preference.mode}."
    if deadline && !deadline.infinite?
      Error::Timeout.new(msg)
    else
      Error::ServerSelection.new msg
    end
  end

  private def pin_selection_timeout_error(address : String, deadline : Mongo::Deadline?)
    msg = "Timeout (#{@options.server_selection_timeout}) reached while waiting for pinned server #{address} to become selectable."
    if deadline && !deadline.infinite?
      Error::Timeout.new(msg)
    else
      Error::ServerSelection.new msg
    end
  end

  private def find_suitable_servers(command, args, read_preference : ReadPreference, deprioritized : Array(String)? = nil) : Array(SDAM::ServerDescription)
    write = WithReadPreference.must_use_primary_command?(command, args)
    SDAM::Selector.suitable_servers(
      topology.type,
      topology.servers,
      read_preference,
      write: write,
      heartbeat_frequency: @options.heartbeat_frequency,
      deprioritized: deprioritized
    )
  end
end
