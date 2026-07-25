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

  property type : TopologyType = :unknown
  # The replica set name.
  property set_name : String? = nil
  # The largest setVersion ever reported by a primary.
  property max_set_version : Int32? = nil
  # The largest electionId ever reported by a primary.
  property max_election_id : BSON::ObjectId? = nil
  # A set of ServerDescription instances.
  property servers : Array(ServerDescription) = [] of ServerDescription
  # For single-threaded clients, whether the topology must be re-scanned.
  property stale : Bool = false
  # False if any server's wire protocol version range is incompatible with the client's.
  property compatible : Bool = true
  # The error message if "compatible" is false, otherwise nil.
  property compatibility_error : String? = nil
  # See logical session timeout.
  property logical_session_timeout_minutes : Int32? = nil

  def initialize(@client : Mongo::Client, seeds : Array(String), options : Mongo::Options)
    seeds.each do |seed|
      if seed.ends_with? ".sock"
        @servers << ServerDescription.new(seed)
      else
        split = seed.split(':')
        host = split[0]
        port = split[1]? || "27017"
        @servers << ServerDescription.new("#{host.downcase}:#{port}")
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
    end
  end

  def clone : TopologyDescription
    copy = TopologyDescription.new(@client, [] of String, Mongo::Options.new)
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
    if old_description != new_description
      @client.emit_sdam_event(Monitoring::SDAM::ServerDescriptionChangedEvent.new(
        @client.object_id, new_description.address, old_description, new_description
      ))
    end

    erase_logical_session_timeout = false
    if new_description.data_bearing?
      min_logical_session_timeout = new_description.logical_session_timeout_minutes
      erase_logical_session_timeout = new_description.logical_session_timeout_minutes.nil?
    end

    # see: https://github.com/mongodb/specifications/blob/master/source/server-discovery-and-monitoring/server-discovery-and-monitoring.rst#logical-session-timeout
    @servers = servers.map do |desc|
      if desc.data_bearing?
        min_logical_session_timeout.try do |min|
          desc.logical_session_timeout_minutes.try do |lstm|
            min_logical_session_timeout = lstm if lstm < min
          end
        end
        erase_logical_session_timeout = true if desc.logical_session_timeout_minutes.nil?
      end

      if desc.address == old_description.address
        new_description
      else
        desc
      end
    end

    @logical_session_timeout_minutes = min_logical_session_timeout if min_logical_session_timeout
    @logical_session_timeout_minutes = nil if erase_logical_session_timeout
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

  def update(old_description : ServerDescription, new_description : ServerDescription)
    @lock.synchronize do
      previous_topology = self.clone

      current_server = @servers.find { |s| s.address == old_description.address }
      if current_server
        unless is_newer_or_equal_topology_version?(current_server.topology_version, new_description.topology_version)
          return
        end
      end

      # see: https://github.com/mongodb/specifications/blob/master/source/server-discovery-and-monitoring/server-discovery-and-monitoring.rst#updating-the-topologydescription
      if @type.single? && set_name.try { |name| new_description.set_name != name }
        replace_description(old_description, ServerDescription.new(old_description.address))
        return
      end

      replace_description(old_description, new_description)

      unless new_description.type.unknown?
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

      if previous_topology.type != @type || previous_topology.servers != @servers
        @client.emit_sdam_event(Monitoring::SDAM::TopologyDescriptionChangedEvent.new(
          @client.object_id, previous_topology, self.clone
        ))
      end
    end
  ensure
    @client.on_topology_update
  end

  def has_primary?
    @servers.any? &.type.rs_primary?
  end

  def update_possible_primary(primary_address : String)
    if server = @servers.find &.address.== primary_address
      server.type = :possible_primary if server.type.unknown?
    end
  end

  # This subroutine is executed with the ServerDescription from Standalone (including a slave) when the TopologyType is Unknown.
  def update_unknown_with_standalone(description)
    return unless servers.any? &.address.== description.address
    if servers.size == 1
      @type = :single
    else
      remove(description)
    end
  end

  # This subroutine is executed with the ServerDescription from an RSSecondary, RSArbiter, or RSOther when the TopologyType is ReplicaSetNoPrimary.
  def update_rs_without_primary(description)
    return unless servers.any? &.address.== description.address

    @set_name ||= description.set_name

    return remove(description) unless @set_name == description.set_name

    {
      description.hosts,
      description.passives,
      description.arbiters,
    }.each &.try &.each do |addr_str|
      unless @servers.any? &.address.==(addr_str)
        @servers << ServerDescription.new(addr_str)
        @client.emit_sdam_event(Monitoring::SDAM::ServerOpeningEvent.new(@client.object_id, addr_str))
      end
    end

    unless (primary_address = description.primary).nil?
      update_possible_primary(primary_address)
    end

    remove(description) if (me = description.me) && description.address != me.downcase
  end

  # This subroutine is executed with the ServerDescription from an RSSecondary, RSArbiter, or RSOther when the TopologyType is ReplicaSetWithPrimary.
  def update_rs_with_primary_from_member(description)
    return unless servers.any? &.address.== description.address

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
    return unless servers.any? &.address.== description.address

    @set_name ||= description.set_name

    if @set_name != description.set_name
      remove(description)
      check_if_has_primary
      return
    end

    set_version = description.set_version
    election_id = description.election_id
    max_set_version = @max_set_version
    max_election_id = @max_election_id
    if !set_version.nil? && !election_id.nil?
      if (
           !max_set_version.nil? &&
           !max_election_id.nil? && (
             max_set_version > set_version || (
               max_set_version == set_version &&
               max_election_id.data > election_id.data
             )
           )
         )
        # Stale primary.
        replace_description(description, ServerDescription.new(description.address))
        check_if_has_primary
        return
      end

      @max_election_id = description.election_id
    end

    if !set_version.nil? && (max_set_version.nil? || set_version > max_set_version)
      @max_set_version = description.set_version
    end

    @servers = @servers.map do |server|
      if server.address != description.address && server.type.rs_primary?
        ServerDescription.new(server.address)
      else
        server
      end
    end

    {
      description.hosts,
      description.passives,
      description.arbiters,
    }.each do |addresses|
      addresses.try &.each do |address|
        address = address.downcase
        unless @servers.any? &.address.== address
          @servers << ServerDescription.new(address)
          @client.emit_sdam_event(Monitoring::SDAM::ServerOpeningEvent.new(@client.object_id, address))
        end
      end
    end

    @servers = @servers.compact_map do |server|
      in_scope = {description.hosts, description.passives, description.arbiters}.any? do |addrs|
        addrs && addrs.any? { |addr| addr.downcase == server.address }
      end
      server if in_scope
    end

    check_if_has_primary
  end

  # Set TopologyType to ReplicaSetWithPrimary if there is an RSPrimary in TopologyDescription.servers, otherwise set it to ReplicaSetNoPrimary.
  def check_if_has_primary
    if @servers.find &.type.rs_primary?
      @type = :replica_set_with_primary
    else
      @type = :replica_set_no_primary
    end
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
