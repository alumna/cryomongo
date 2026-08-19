require "json"
require "../../src/cryomongo"

# Build topology and read preference objects from official JSON fixtures.
# No mocks and no MongoDB process.
module Mongo::SpecSupport
  extend self

  def topology_type(value : String) : Mongo::SDAM::TopologyDescription::TopologyType
    Mongo::SDAM::TopologyDescription::TopologyType.parse(value)
  end

  def server_type(value : String) : Mongo::SDAM::ServerDescription::ServerType
    Mongo::SDAM::ServerDescription::ServerType.parse(value)
  end

  def json_i64(value : JSON::Any) : Int64
    if h = value.as_h?
      if n = h["$numberLong"]?
        return n.as_s.to_i64
      end
    end
    if s = value.as_s?
      return s.to_i64
    end
    value.as_i64
  end

  def json_ms(value : JSON::Any) : Time::Span
    json_i64(value).milliseconds
  end

  def server_from_json(json : JSON::Any) : Mongo::SDAM::ServerDescription
    h = json.as_h
    desc = Mongo::SDAM::ServerDescription.new(h["address"].as_s)
    if type = h["type"]?.try(&.as_s?)
      desc.type = server_type(type)
    end
    if rtt = h["avg_rtt_ms"]?
      unless rtt.raw.is_a?(String) && rtt.as_s.upcase == "NULL"
        desc.round_trip_time = json_ms(rtt)
      end
    end
    if max_w = h["maxWireVersion"]?
      desc.max_wire_version = max_w.as_i
    end
    if min_w = h["minWireVersion"]?
      desc.min_wire_version = min_w.as_i
    end
    if updated = h["lastUpdateTime"]?
      desc.last_update_time = Time.unix_ms(json_i64(updated))
    end
    if last_write = h["lastWrite"]?.try(&.as_h?)
      if date = last_write["lastWriteDate"]?
        desc.last_write_date = Time.unix_ms(json_i64(date))
      end
    end
    if tags = h["tags"]?.try(&.as_h?)
      desc.tags = BSON.from_json(tags.to_json)
    end
    if set_name = h["setName"]?.try(&.as_s?)
      desc.set_name = set_name
    end
    desc
  end

  def servers_from_json(json : JSON::Any) : Array(Mongo::SDAM::ServerDescription)
    json.as_a.map { |item| server_from_json(item) }
  end

  def read_preference_from_json(json : JSON::Any?) : Mongo::ReadPreference
    return Mongo::PRIMARY_READ_PREFERENCE unless json
    h = json.as_h
    mode = h["mode"]?.try(&.as_s?) || "primary"
    tags = nil
    if tag_sets = h["tag_sets"]?.try(&.as_a?) || h["tagSets"]?.try(&.as_a?)
      tags = tag_sets.map { |set| BSON.from_json(set.to_json) }
    end
    max_s = h["maxStalenessSeconds"]?.try { |v| json_i64(v).to_i32 }
    Mongo::ReadPreference.new(mode: mode, tags: tags, max_staleness_seconds: max_s)
  end

  def heartbeat_frequency(json : JSON::Any) : Time::Span
    if ms = json["heartbeatFrequencyMS"]?.try(&.as_i?)
      ms.milliseconds
    else
      Mongo::SDAM::Selector::DEFAULT_HEARTBEAT
    end
  end
end
