class Mongo::SDAM::TopologyDescription
  enum TopologyType
    Single
    ReplicaSetNoPrimary
    ReplicaSetWithPrimary
    Sharded
    LoadBalanced
    Unknown
  end

  @lock : Sync::Mutex = Sync::Mutex.new

  getter type : TopologyType = :unknown
  protected setter type

  # The replica set name.
  getter set_name : String? = nil
  protected setter set_name

  # The largest setVersion ever reported by a primary.
  getter max_set_version : Int32? = nil
  protected setter max_set_version

  # The largest electionId ever reported by a primary.
  getter max_election_id : BSON::ObjectId? = nil
  protected setter max_election_id

  # A set of ServerDescription instances.
  getter servers : Array(ServerDescription) = [] of ServerDescription
  protected setter servers

  # For single-threaded clients, whether the topology must be re-scanned.
  getter stale : Bool = false
  protected setter stale

  # False if any server's wire protocol version range is incompatible with the client's.
  getter compatible : Bool = true
  protected setter compatible

  # The error message if "compatible" is false, otherwise nil.
  getter compatibility_error : String? = nil
  protected setter compatibility_error

  # See logical session timeout.
  getter logical_session_timeout_minutes : Int32? = nil
  protected setter logical_session_timeout_minutes

  # Fast-path bare initializer for #clone and empty topologies
  def initialize(@client : Mongo::Client)
  end

  def initialize(@client : Mongo::Client, seeds : Array(String), options : Mongo::Options)
    seeds.each do |seed|
      if seed.ends_with?(".sock")
        @servers << ServerDescription.new(seed)
      elsif colon = seed.byte_rindex(':')
        if seed.ends_with?(']')
          @servers << ServerDescription.new("#{seed.downcase}:27017")
        else
          host = seed.byte_slice(0, colon).downcase
          port = seed.byte_slice(colon + 1)
          @servers << ServerDescription.new("#{host}:#{port}")
        end
      else
        @servers << ServerDescription.new("#{seed.downcase}:27017")
      end
    end

    if options.direct_connection
      @type = :single
    end

    if options.replica_set
      @type = :replica_set_no_primary if @type.unknown?
      @set_name = options.replica_set
    end

    # Safely handle uninitialized raw HTTP params during cloning
    if options.raw?.try(&.["loadbalanced"]?) == "true"
      @type = :load_balanced
      @servers.each { |s| s.type = :load_balancer }
    end
  end

  def clone : TopologyDescription
    copy = TopologyDescription.new(@client)
    copy.type = @type
    copy.set_name = @set_name
    copy.max_set_version = @max_set_version
    copy.max_election_id = @max_election_id
    copy.servers = @servers.map(&.clone)
    copy.stale = @stale
    copy.compatible = @compatible
    copy.compatibility_error = @compatibility_error
    copy.logical_session_timeout_minutes = @logical_session_timeout_minutes
    copy
  end

  def replace_description(old_description, new_description)
    effective_new = if @type.load_balanced? && !new_description.type.load_balancer?
                      copy = new_description.clone
                      copy.type = :load_balancer
                      copy
                    else
                      new_description
                    end

    if old_description != effective_new
      @client.emit_sdam_event(Monitoring::SDAM::ServerDescriptionChangedEvent.new(
        @client.object_id, effective_new.address, old_description, effective_new
      ))
    end

    @servers = @servers.map do |desc|
      desc.address == old_description.address ? effective_new : desc
    end

    min_logical_session_timeout = nil.as(Int32?)
    erase_logical_session_timeout = false

    @servers.each do |desc|
      if desc.data_bearing?
        if lstm = desc.logical_session_timeout_minutes
          if min = min_logical_session_timeout
            min_logical_session_timeout = lstm if lstm < min
          else
            min_logical_session_timeout = lstm
          end
        else
          erase_logical_session_timeout = true
        end
      end
    end

    @logical_session_timeout_minutes = erase_logical_session_timeout ? nil : min_logical_session_timeout
  end

  def is_newer_or_equal_topology_version?(current_tv : BSON?, new_tv : BSON?) : Bool
    return true if current_tv.nil? || new_tv.nil?
    pid_current = current_tv["processId"]?
    pid_new = new_tv["processId"]?
    return true if pid_current != pid_new

    counter_current = current_tv["counter"]?.try(&.as(Int64)) || 0_i64
    counter_new = new_tv["counter"]?.try(&.as(Int64)) || 0_i64
    counter_new >= counter_current
  end

  def is_stale_error_topology_version?(current_tv : BSON?, error_tv : BSON?) : Bool
    return false if current_tv.nil? || error_tv.nil?
    pid_current = current_tv["processId"]?
    pid_err = error_tv["processId"]?
    return false if pid_current != pid_err

    counter_current = current_tv["counter"]?.try(&.as(Int64)) || 0_i64
    counter_err = error_tv["counter"]?.try(&.as(Int64)) || 0_i64
    counter_err <= counter_current
  end

  def update(old_description : ServerDescription, new_description : ServerDescription)
    topology_changed = false

    @lock.synchronize do
      # Snapshot the entire state *before* any mutations for accurate SDAM events
      previous_type = @type
      previous_set_name = @set_name
      previous_max_set_version = @max_set_version
      previous_max_election_id = @max_election_id
      previous_servers = @servers.map(&.clone)
      previous_stale = @stale
      previous_compatible = @compatible
      previous_compatibility_error = @compatibility_error
      previous_logical_session_timeout_minutes = @logical_session_timeout_minutes

      current_server = @servers.find { |s| s.address == old_description.address }
      if current_server
        unless is_newer_or_equal_topology_version?(current_server.topology_version, new_description.topology_version)
          return
        end
      end

      # see: https://github.com/mongodb/specifications/blob/master/source/server-discovery-and-monitoring/server-discovery-and-monitoring.rst#updating-the-topologydescription
      if @type.single? && @set_name.try { |name| new_description.set_name != name }
        replace_description(old_description, ServerDescription.new(old_description.address))
      else
        replace_description(old_description, new_description)

        unless new_description.type.unknown? || @type.load_balanced?
          if new_description.min_wire_version > Client::MAX_WIRE_VERSION
            @compatible = false
            @compatibility_error = "Server at #{new_description.address} requires wire version #{new_description.min_wire_version}, but this version of cryomongo only supports up to #{Client::MAX_WIRE_VERSION}."
          elsif new_description.max_wire_version < Client::MIN_WIRE_VERSION
            @compatible = false
            @compatibility_error = "Server at #{new_description.address} requires wire version #{new_description.max_wire_version}, but this version of cryomongo requires at least #{Client::MIN_WIRE_VERSION}."
          else
            @compatible = true
          end
        end

        case new_description.type
        when .unknown?
          check_if_has_primary if @type.replica_set_with_primary?
        when .standalone?
          case @type
          when .unknown?
            update_unknown_with_standalone(new_description)
          when .sharded?, .replica_set_no_primary?
            remove(new_description)
          when .replica_set_with_primary?
            remove(new_description)
            check_if_has_primary
          else
            # ignore
          end
        when .mongos?
          case @type
          when .unknown?
            @type = :sharded
          when .replica_set_no_primary?
            remove(new_description)
          when .replica_set_with_primary?
            remove(new_description)
            check_if_has_primary
          else
            # ignore
          end
        when .rs_primary?
          case @type
          when .unknown?
            update_rs_from_primary(new_description)
          when .sharded?
            remove(new_description)
          when .replica_set_no_primary?
            @type = :replica_set_with_primary
            update_rs_from_primary(new_description)
          when .replica_set_with_primary?
            update_rs_from_primary(new_description)
          else
            # ignore
          end
        when .rs_secondary?, .rs_arbiter?, .rs_other?
          case @type
          when .unknown?
            @type = :replica_set_no_primary
            update_rs_without_primary(new_description)
          when .sharded?
            remove(new_description)
          when .replica_set_no_primary?
            update_rs_without_primary(new_description)
          when .replica_set_with_primary?
            update_rs_with_primary_from_member(new_description)
          else
            # ignore
          end
        when .rs_ghost?
          case @type
          when .sharded?
            remove(new_description)
          when .replica_set_with_primary?
            check_if_has_primary
          else
            # ignore
          end
        else
          # ignore
        end
      end

      if previous_type != @type || previous_servers != @servers
        previous_topology = TopologyDescription.new(@client)
        previous_topology.type = previous_type
        previous_topology.set_name = previous_set_name
        previous_topology.max_set_version = previous_max_set_version
        previous_topology.max_election_id = previous_max_election_id
        previous_topology.servers = previous_servers
        previous_topology.stale = previous_stale
        previous_topology.compatible = previous_compatible
        previous_topology.compatibility_error = previous_compatibility_error
        previous_topology.logical_session_timeout_minutes = previous_logical_session_timeout_minutes

        @client.emit_sdam_event(Monitoring::SDAM::TopologyDescriptionChangedEvent.new(
          @client.object_id, previous_topology, self.clone
        ))
      end

      topology_changed = true
    end
  ensure
    @client.on_topology_update if topology_changed
  end

  def has_primary?
    @servers.any?(&.type.rs_primary?)
  end

  def update_possible_primary(primary_address : String)
    if server = @servers.find(&.address.==(primary_address))
      server.type = :possible_primary if server.type.unknown?
    end
  end

  # This subroutine is executed with the ServerDescription from Standalone (including a slave) when the TopologyType is Unknown.
  def update_unknown_with_standalone(description)
    return unless @servers.any?(&.address.==(description.address))
    if @servers.size == 1
      @type = :single
    else
      remove(description)
    end
  end

  # This subroutine is executed with the ServerDescription from an RSSecondary, RSArbiter, or RSOther when the TopologyType is ReplicaSetNoPrimary.
  def update_rs_without_primary(description)
    return unless @servers.any?(&.address.==(description.address))

    @set_name ||= description.set_name

    return remove(description) unless @set_name == description.set_name

    existing_addresses = Set(String).new
    @servers.each { |s| existing_addresses << s.address }

    {
      description.hosts,
      description.passives,
      description.arbiters,
    }.each do |addresses|
      addresses.try &.each do |addr_str|
        address = addr_str.downcase
        unless existing_addresses.includes?(address)
          @servers << ServerDescription.new(address)
          existing_addresses << address
          @client.emit_sdam_event(Monitoring::SDAM::ServerOpeningEvent.new(@client.object_id, address))
        end
      end
    end

    unless (primary_address = description.primary).nil?
      update_possible_primary(primary_address)
    end

    remove(description) if (me = description.me) && description.address != me.downcase
  end

  # This subroutine is executed with the ServerDescription from an RSSecondary, RSArbiter, or RSOther when the TopologyType is ReplicaSetWithPrimary.
  def update_rs_with_primary_from_member(description)
    return unless @servers.any?(&.address.==(description.address))

    # SetName is never null here.
    if @set_name != description.set_name
      remove(description)
      check_if_has_primary
      return
    end

    if (me = description.me) && description.address != me.downcase
      remove(description)
      check_if_has_primary
      return
    end

    unless has_primary?
      @type = :replica_set_no_primary
      unless (primary_address = description.primary).nil?
        update_possible_primary(primary_address)
      end
    end
  end

  # This subroutine is executed with a ServerDescription of type RSPrimary.
  def update_rs_from_primary(description)
    return unless @servers.any?(&.address.==(description.address))

    @set_name ||= description.set_name

    if @set_name != description.set_name
      remove(description)
      check_if_has_primary
      return
    end

    set_version = description.set_version
    election_id = description.election_id

    if description.max_wire_version >= 17
      # MongoDB 6.0+ Tuple Comparison
      is_stale = false

      elec_cmp = if election_id && @max_election_id
                   election_id.data <=> @max_election_id.try(&.data)
                 elsif election_id
                   1
                 elsif @max_election_id
                   -1
                 else
                   0
                 end

      set_cmp = if set_version && @max_set_version
                  set_version <=> @max_set_version.not_nil!
                elsif set_version
                  1
                elsif @max_set_version
                  -1
                else
                  0
                end

      if elec_cmp > 0 || (elec_cmp == 0 && set_cmp >= 0)
        @max_election_id = election_id
        @max_set_version = set_version
      else
        is_stale = true
      end

      if is_stale
        stale_desc = ServerDescription.new(description.address)
        stale_desc.error = "primary marked stale due to electionId/setVersion mismatch"
        replace_description(description, stale_desc)
        check_if_has_primary
        return
      end
    else
      # Pre-6.0 Tuple Comparison
      if !set_version.nil? && !election_id.nil?
        if max_set_v = @max_set_version
          if max_elec_id = @max_election_id
            if max_set_v > set_version || (max_set_v == set_version && max_elec_id.data > election_id.data)
              stale_desc = ServerDescription.new(description.address)
              stale_desc.error = "primary marked stale due to electionId/setVersion mismatch"
              replace_description(description, stale_desc)
              check_if_has_primary
              return
            end
          end
        end
        @max_election_id = election_id
      end

      if !set_version.nil?
        max_set_v = @max_set_version
        if max_set_v.nil? || set_version > max_set_v
          @max_set_version = set_version
        end
      end
    end

    @servers.dup.each do |server|
      if server.address != description.address && server.type.rs_primary?
        stale_desc = ServerDescription.new(server.address)
        stale_desc.error = "primary marked stale due to discovery of newer primary"
        replace_description(server, stale_desc)
      end
    end

    existing_addresses = Set(String).new
    @servers.each { |s| existing_addresses << s.address }

    {
      description.hosts,
      description.passives,
      description.arbiters,
    }.each do |addresses|
      addresses.try &.each do |addr_str|
        address = addr_str.downcase
        unless existing_addresses.includes?(address)
          @servers << ServerDescription.new(address)
          existing_addresses << address
          @client.emit_sdam_event(Monitoring::SDAM::ServerOpeningEvent.new(@client.object_id, address))
        end
      end
    end

    valid_addresses = Set(String).new
    {description.hosts, description.passives, description.arbiters}.each do |addrs|
      addrs.try &.each { |addr| valid_addresses << addr.downcase }
    end

    @servers.reject! do |server|
      unless valid_addresses.includes?(server.address)
        @client.emit_sdam_event(Monitoring::SDAM::ServerClosedEvent.new(@client.object_id, server.address))
        true
      else
        false
      end
    end

    check_if_has_primary
  end

  # Set TopologyType to ReplicaSetWithPrimary if there is an RSPrimary in TopologyDescription.servers, otherwise set it to ReplicaSetNoPrimary.
  def check_if_has_primary
    @type = @servers.any?(&.type.rs_primary?) ? TopologyType::ReplicaSetWithPrimary : TopologyType::ReplicaSetNoPrimary
  end

  def remove(server_description)
    idx = @servers.index { |s| s.address == server_description.address }
    if idx
      @servers.delete_at(idx)
      @client.emit_sdam_event(Monitoring::SDAM::ServerClosedEvent.new(@client.object_id, server_description.address))
    end
  end

  def supports_sessions?
    !@type.unknown? && !@logical_session_timeout_minutes.nil?
  end

  def supports_cluster_time?
    !@type.unknown? && !@type.single?
  end
end
