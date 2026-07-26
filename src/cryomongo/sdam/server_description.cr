require "../commands/replication/hello"

class Mongo::SDAM::ServerDescription
  enum ServerType
    Standalone
    Mongos
    PossiblePrimary
    RSPrimary
    RSSecondary
    RSArbiter
    RSOther
    RSGhost
    LoadBalancer
    Unknown
  end

  # The hostname or IP, and the port number that the client connects to.
  getter address : String
  # Information about the last error related to this server
  property error : String? = nil
  # The duration of the ismaster call.
  getter round_trip_time : Time::Span = 0.seconds
  # A 64-bit BSON datetime or null. The "lastWriteDate" from the server's most recent ismaster response.
  property last_write_date : Time? = nil
  # An opaque value representing the position in the oplog of the most recently seen write.
  property op_time : BSON? = nil
  # A ServerType enum value.
  property type : ServerType = :unknown
  # The wire protocol version range supported by the server.
  property min_wire_version : Int32 = 0
  property max_wire_version : Int32 = 0
  # The hostname or IP, and the port number, that this server was configured with in the replica set.
  property me : String? = nil
  # Sets of addresses. This server's opinion of the replica set's members, if any.
  property hosts : Array(String)? = [] of String
  property passives : Array(String)? = [] of String
  property arbiters : Array(String)? = [] of String
  # Map from string to string.
  property tags : BSON? # Hash(String, String) = {} of String => String
  property set_name : String? = nil
  property set_version : Int32? = nil
  # An ObjectId, if this is a MongoDB 2.6+ replica set member that believes it is primary.
  property election_id : BSON::ObjectId? = nil
  # This server's opinion of who the primary is.
  property primary : String? = nil
  # When this server was last checked.
  property last_update_time : Time = Time::UNIX_EPOCH
  property logical_session_timeout_minutes : Int32? = nil
  # The "topologyVersion" from the server's most recent ismaster response or State Change Error.
  property topology_version : BSON? = nil

  def initialize(@address : String)
  end

  private macro from_is_master(fields, is_master)
    {% for field in fields %}
      @{{field.id}} = {{is_master.id}}.{{field.id}}
    {% end %}
  end

  def initialize(address : String, hello_result : Commands::Hello::Result, @round_trip_time : Time::Span)
    @address = address.downcase

    if hello_result.ok != 1.0
      @type = :unknown
      return
    end

    from_is_master(%w(
      min_wire_version
      max_wire_version
      logical_session_timeout_minutes
      set_name
      set_version
      primary
      hosts
      passives
      arbiters
      me
      election_id
      tags
    ), hello_result)

    @last_update_time = Time.utc
    @last_write_date = hello_result.last_write.try &.["lastWriteDate"]?.try &.as(Time)
    @op_time = hello_result.last_write.try &.["opTime"]?.try &.as(BSON)
    @topology_version = hello_result.topology_version

    if hello_result.msg === "isdbgrid"
      @type = :mongos
    elsif hello_result.isreplicaset
      @type = :rs_ghost
    elsif hello_result.set_name.nil?
      @type = :standalone
    elsif hello_result.ismaster || hello_result.isWritablePrimary # <== Check both legacy and modern keys
      @type = :rs_primary
    elsif hello_result.hidden
      @type = :rs_other
    elsif hello_result.secondary
      @type = :rs_secondary
    elsif hello_result.arbiter_only
      @type = :rs_arbiter
    else
      @type = :rs_other
    end
  end

  def update(other : ServerDescription)
    {% begin %}
      {% for ivar in @type.instance_vars %}
        @{{ivar.id}} = other.{{ivar.id}}
      {% end %}
    {% end %}
  end

  def clone : ServerDescription
    copy = ServerDescription.new(@address)
    copy.error = @error
    copy.type = @type
    copy.min_wire_version = @min_wire_version
    copy.max_wire_version = @max_wire_version
    copy.me = @me
    copy.hosts = @hosts.try(&.dup)
    copy.passives = @passives.try(&.dup)
    copy.arbiters = @arbiters.try(&.dup)
    copy.tags = @tags
    copy.set_name = @set_name
    copy.set_version = @set_version
    copy.election_id = @election_id
    copy.primary = @primary
    copy.last_update_time = @last_update_time
    copy.logical_session_timeout_minutes = @logical_session_timeout_minutes
    copy.topology_version = @topology_version
    copy
  end

  def_equals @address, @error, @type, @min_wire_version, @max_wire_version,
    @me, @hosts, @passives, @arbiters, @tags, @set_name, @set_version, @election_id,
    @primary, @logical_session_timeout_minutes, @topology_version

  def data_bearing?
    @type.mongos? || @type.rs_primary? || @type.rs_secondary? || @type.standalone?
  end

  def primary_or_possible?
    self.type.rs_primary? || self.type.possible_primary?
  end

  def unknown_or_ghost?
    self.type.unknown? || self.type.rs_ghost?
  end

  def supports_retryable_writes?
    self.max_wire_version >= 6 &&
      self.logical_session_timeout_minutes &&
      !self.type.standalone?
  end

  def supports_retryable_reads?
    self.max_wire_version >= 6
  end
end
