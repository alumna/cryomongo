# topologyVersion compare for hello updates and application errors.
# Spec: a real state change increments the counter, so an error whose
# counter is not greater is stale. failCommand 91 also increments, but
# the server stays Primary. A streaming hello can publish that same
# counter first (Darwin command slices vs one monitor wait). The live
# path still marks Unknown when the type is still writable.
module Mongo::SDAM::TopologyVersion
  extend self

  # Incoming vs current. Nil on either side, or a new processId, means
  # incoming is newer. 1 newer, 0 equal, -1 older.
  def compare(current_tv : BSON?, incoming_tv : BSON?) : Int32
    return 1 if current_tv.nil? || incoming_tv.nil?
    pid_current = current_tv["processId"]?
    pid_incoming = incoming_tv["processId"]?
    return 1 if pid_current != pid_incoming

    counter_current = counter(current_tv)
    counter_incoming = counter(incoming_tv)
    if counter_incoming > counter_current
      1
    elsif counter_incoming < counter_current
      -1
    else
      0
    end
  end

  # Server sends Int64. BSON may also yield Int32. Do not `.as(Int64)`
  # (that raises on Int32 and would skip Unknown).
  def counter(tv : BSON) : Int64
    value = tv["counter"]?
    case value
    when Int
      value.to_i64
    else
      0_i64
    end
  end

  # Live application error. Strictly older TV is always stale. Equal TV
  # is stale only after this version is already Unknown or a non-writable
  # replica-set role (monitor already applied the new state). Equal TV on
  # Primary / Mongos / Standalone still marks Unknown.
  def application_error_stale?(current : ServerDescription, error_tv : BSON?) : Bool
    cmp = compare(current.topology_version, error_tv)
    return true if cmp < 0
    return false if cmp > 0
    current.type.unknown? ||
      current.type.rs_secondary? ||
      current.type.rs_arbiter? ||
      current.type.rs_other? ||
      current.type.rs_ghost?
  end
end
