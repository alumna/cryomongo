# Server selection and max-staleness filters. No Client, no network.
# Spec tests build ServerDescription objects and call these methods.
module Mongo::SDAM::Selector
  extend self

  IDLE_WRITE_PERIOD       = 10.seconds
  SMALLEST_MAX_STALENESS  = 90.seconds
  DEFAULT_HEARTBEAT       = 10.seconds
  DEFAULT_LOCAL_THRESHOLD = 15.milliseconds

  # Servers that can take this operation, before the latency window.
  def suitable_servers(
    topology_type : TopologyDescription::TopologyType,
    servers : Array(ServerDescription),
    read_preference : ReadPreference,
    *,
    write : Bool = false,
    heartbeat_frequency : Time::Span = DEFAULT_HEARTBEAT,
  ) : Array(ServerDescription)
    validate_max_staleness!(topology_type, servers, read_preference, heartbeat_frequency)

    case topology_type
    when .unknown?
      [] of ServerDescription
    when .single?
      servers
    when .load_balanced?
      servers.select(&.type.load_balancer?)
    when .sharded?
      servers.select(&.type.mongos?)
    when .replica_set_no_primary?, .replica_set_with_primary?
      if write
        servers.select(&.type.rs_primary?)
      else
        suitable_replica_set(topology_type, servers, read_preference, heartbeat_frequency)
      end
    else
      [] of ServerDescription
    end
  end

  # Suitable servers whose RTT is within localThresholdMS of the fastest.
  def in_latency_window(
    servers : Array(ServerDescription),
    local_threshold : Time::Span = DEFAULT_LOCAL_THRESHOLD,
  ) : Array(ServerDescription)
    return servers.dup if servers.size < 2

    min_rtt = servers.min_of(&.round_trip_time)
    servers.select { |server|
      server.round_trip_time - min_rtt <= local_threshold
    }
  end

  # One server from the latency window, or nil if the list is empty.
  def pick(servers : Array(ServerDescription), local_threshold : Time::Span = DEFAULT_LOCAL_THRESHOLD) : ServerDescription?
    case servers.size
    when 0
      nil
    when 1
      servers[0]
    else
      min_rtt = servers.min_of(&.round_trip_time)
      n = 0
      servers.each { |server| n += 1 if server.round_trip_time - min_rtt <= local_threshold }
      return nil if n == 0
      chosen = Random.rand(n)
      servers.each do |server|
        next unless server.round_trip_time - min_rtt <= local_threshold
        return server if chosen == 0
        chosen -= 1
      end
      nil
    end
  end

  def validate_max_staleness!(
    topology_type : TopologyDescription::TopologyType,
    servers : Array(ServerDescription),
    read_preference : ReadPreference,
    heartbeat_frequency : Time::Span,
  ) : Nil
    max_s = read_preference.max_staleness_seconds
    return if max_s.nil? || max_s < 0

    mode = read_preference.mode.downcase
    if mode.empty? || mode == "primary"
      raise Mongo::Error::ServerSelection.new("maxStalenessSeconds cannot be used with read preference primary")
    end

    # Standalone, sharded, unknown, and load-balanced topologies ignore the value.
    return unless topology_type.replica_set_with_primary? || topology_type.replica_set_no_primary?

    max_span = max_s.seconds
    min_from_heartbeat = heartbeat_frequency + IDLE_WRITE_PERIOD
    if max_span < SMALLEST_MAX_STALENESS || max_span < min_from_heartbeat
      raise Mongo::Error::ServerSelection.new("maxStalenessSeconds is too small")
    end
  end

  private def suitable_replica_set(
    topology_type : TopologyDescription::TopologyType,
    servers : Array(ServerDescription),
    read_preference : ReadPreference,
    heartbeat_frequency : Time::Span,
  ) : Array(ServerDescription)
    mode = read_preference.mode.downcase
    mode = "primary" if mode.empty?

    case mode
    when "primary"
      servers.select(&.type.rs_primary?)
    when "secondary"
      filter_tags(filter_staleness(servers.select(&.type.rs_secondary?), servers, topology_type, read_preference, heartbeat_frequency), read_preference)
    when "nearest"
      candidates = servers.select { |s| s.type.rs_primary? || s.type.rs_secondary? }
      filter_tags(filter_staleness(candidates, servers, topology_type, read_preference, heartbeat_frequency), read_preference)
    when "secondarypreferred"
      secondaries = suitable_replica_set(topology_type, servers, with_mode(read_preference, "secondary"), heartbeat_frequency)
      secondaries.empty? ? servers.select(&.type.rs_primary?) : secondaries
    when "primarypreferred"
      primaries = servers.select(&.type.rs_primary?)
      primaries.empty? ? suitable_replica_set(topology_type, servers, with_mode(read_preference, "secondary"), heartbeat_frequency) : primaries
    else
      [] of ServerDescription
    end
  end

  private def with_mode(read_preference : ReadPreference, mode : String) : ReadPreference
    ReadPreference.new(
      mode: mode,
      tags: read_preference.tags,
      max_staleness_seconds: read_preference.max_staleness_seconds,
      hedge: read_preference.hedge
    )
  end

  private def filter_staleness(
    candidates : Array(ServerDescription),
    all : Array(ServerDescription),
    topology_type : TopologyDescription::TopologyType,
    read_preference : ReadPreference,
    heartbeat_frequency : Time::Span,
  ) : Array(ServerDescription)
    max_s = read_preference.max_staleness_seconds
    return candidates if max_s.nil? || max_s < 0
    max_staleness = max_s.seconds

    candidates.select { |server|
      next true unless server.type.rs_secondary?

      if topology_type.replica_set_with_primary?
        primary = all.find(&.type.rs_primary?)
        next false unless primary
        server_write = server.last_write_date
        primary_write = primary.last_write_date
        next false unless server_write && primary_write
        staleness = (server.last_update_time - server_write) - (primary.last_update_time - primary_write) + heartbeat_frequency
        staleness <= max_staleness
      else
        secondaries = all.select(&.type.rs_secondary?)
        max_write = secondaries.max_of? { |s| s.last_write_date || Time::UNIX_EPOCH }
        next false unless max_write
        server_write = server.last_write_date
        next false unless server_write
        staleness = max_write - server_write + heartbeat_frequency
        staleness <= max_staleness
      end
    }
  end

  private def filter_tags(servers : Array(ServerDescription), read_preference : ReadPreference) : Array(ServerDescription)
    tag_sets = read_preference.tags
    return servers unless tag_sets && tag_sets.size > 0

    tag_sets.each do |tags|
      matched = servers.select { |server|
        tags.all? { |key, value|
          if server_tags = server.tags
            server_tags[key]? == value
          else
            false
          end
        }
      }
      return matched unless matched.empty?
    end

    [] of ServerDescription
  end
end
