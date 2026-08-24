class Mongo::Client
  private def server_selection(command, args, read_preference : ReadPreference, deadline : Mongo::Deadline? = nil, deprioritized : Array(String)? = nil) : SDAM::ServerDescription
    # See: https://github.com/mongodb/specifications/blob/master/source/server-selection/server-selection.rst#multi-threaded-or-asynchronous-server-selection
    # Use a monotonic clock. Wall time can jump and would shorten or stretch the wait.
    selection_start = Time.instant
    selection_timeout = @options.server_selection_timeout
    effective = deadline || Mongo::Deadline.from_options(@options)
    if effective && !effective.infinite?
      left = effective.remaining
      selection_timeout = left if left < selection_timeout
      raise Error::Timeout.new("timed out during server selection") if selection_timeout <= Time::Span.zero
    end
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

  private def selection_timeout_error(read_preference : ReadPreference, deadline : Mongo::Deadline? = nil)
    msg = "Timeout (#{@options.server_selection_timeout}) reached while trying to select a suitable server with read preference #{read_preference.mode}."
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
