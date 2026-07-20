class Mongo::Client
  private def server_selection(command, args, read_preference : ReadPreference) : SDAM::ServerDescription
    # See: https://github.com/mongodb/specifications/blob/master/source/server-selection/server-selection.rst#multi-threaded-or-asynchronous-server-selection
    selection_start_time = Time.utc
    selection_timeout = selection_start_time + @options.server_selection_timeout

    loop do
      unless topology.compatible
        raise Error::ServerSelection.new topology.compatibility_error
      end

      # Find suitable servers by topology type and operation type
      # Filter the suitable servers by calling the optional, application-provided server selector.
      # If there are any suitable servers, choose one at random from those within the latency window and return it;  otherwise, continue to the next step
      suitable_servers = find_suitable_servers(command, args, read_preference)
      selected_server = suitable_servers.try { |s| select_by_latency(s) }
      return selected_server if selected_server

      # Request an immediate topology check, then block the server selection thread until the topology changes or until the server selection timeout has elapsed
      @monitors.each { |monitor|
        monitor.request_immediate_scan
      }

      select
      when @topology_update.receive
      when timeout selection_timeout - Time.utc
      end

      # If more than serverSelectionTimeoutMS milliseconds have elapsed since the selection start time, raise a server selection error
      if Time.utc > selection_timeout
        raise Error::ServerSelection.new "Timeout (#{@options.server_selection_timeout}) reached while trying to select a suitable server with read preference #{read_preference.mode}."
      end
    end
  end

  private def find_suitable_servers(command, args, read_preference : ReadPreference) : Array(SDAM::ServerDescription)?
    # see: https://github.com/mongodb/specifications/blob/master/source/server-selection/server-selection.rst#topology-type-unknown
    case self.topology.type
    when .unknown?
      nil
    when .single?
      self.topology.servers
    when .replica_set_no_primary?, .replica_set_with_primary?
      if WithReadPreference.must_use_primary_command?(command, args)
        if self.topology.type.replica_set_with_primary?
          select_primary
        else
          nil
        end
      else
        if read_preference.mode == "primary"
          select_primary
        elsif read_preference.mode == "secondary" || read_preference.mode == "nearest"
          servers = select_secondaries
          if read_preference.mode == "nearest"
            servers += select_primary
          end
          servers = filter_by_staleness(servers, read_preference)
          filter_by_tags(servers, read_preference)
        elsif read_preference.mode == "secondaryPreferred"
          result = find_suitable_servers(command, args, ReadPreference.new(mode: "secondary"))
          unless result.try &.size.try &.> 0
            return select_primary
          end
          result
        elsif read_preference.mode == "primaryPreferred"
          result = select_primary
          unless result.try &.size > 0
            return find_suitable_servers(command, args, ReadPreference.new(mode: "secondary"))
          end
          result
        end
      end
    when .sharded?
      self.topology.servers.select &.type.mongos?
    end
  end

  private def select_primary
    self.topology.servers.select &.type.rs_primary?
  end

  private def select_secondaries
    self.topology.servers.select &.type.rs_secondary?
  end

  private def filter_by_staleness(server_descriptions, read_preference) : Array(SDAM::ServerDescription)?
    max_staleness = (read_preference.max_staleness_seconds || -1).seconds
    return server_descriptions unless max_staleness >= 0.seconds
    server_descriptions.select { |server|
      next true unless server.type.rs_secondary?
      if self.topology.type.replica_set_with_primary?
        primary = select_primary[0]
        server_write = server.last_write_date || raise Mongo::Error.new("Secondary missing last_write_date")
        primary_write = primary.last_write_date || raise Mongo::Error.new("Primary missing last_write_date")
        staleness = (server.last_update_time - server_write) - (primary.last_update_time - primary_write) + @options.heartbeat_frequency
      else
        max_write_date = select_secondaries.max_of { |s| s.last_write_date || raise Mongo::Error.new("Secondary missing last_write_date") }
        server_write = server.last_write_date || raise Mongo::Error.new("Secondary missing last_write_date")
        staleness = max_write_date - server_write + @options.heartbeat_frequency
      end
      staleness <= max_staleness
    }
  end

  private def filter_by_tags(server_descriptions, read_preference) : Array(SDAM::ServerDescription)?
    # https://github.com/mongodb/specifications/blob/master/source/server-selection/server-selection.rst#tag-sets
    return server_descriptions unless (tag_sets = read_preference.tags) && tag_sets.size > 0
    server_descriptions.select { |server|
      tag_sets.any? { |tags|
        tags.all? { |key, value|
          server.tags.try &.[key].== value
        }
      }
    }
  end

  private def select_by_latency(server_descriptions) : SDAM::ServerDescription?
    # see: https://github.com/mongodb/specifications/blob/master/source/server-selection/server-selection.rst#selecting-servers-within-the-latency-window
    return server_descriptions[0]? if server_descriptions.size < 2

    min_round_trip_time = server_descriptions.min_of &.round_trip_time
    eligible = server_descriptions.select { |server|
      server.round_trip_time - min_round_trip_time < @options.local_threshold
    }
    eligible.sample(1)[0]
  end
end
