require "json"
require "bson"

module Mongo::Unified::Parse
  extend self

  # Relaxed ExtJSON numbers that fit in Int32 become `$numberInt`.
  # `BSON.from_json` stores a JSON integer as Int64 (Crystal pull parser).
  # Queryable Encryption `bsonType: int` rejects that long.
  # Typed wrappers (`$numberLong`, `$oid`, `$minKey`, …) stay as written.
  # Canonical ExtJSON wrappers. Query operators (`$eq`) are not wrappers.
  EXTJSON_WRAPPERS = {
    "$oid", "$symbol", "$numberInt", "$numberLong", "$numberDouble", "$numberDecimal",
    "$binary", "$uuid", "$code", "$timestamp", "$regularExpression", "$dbPointer",
    "$date", "$minKey", "$maxKey", "$undefined",
  }

  def extjson_wrapper?(key : String) : Bool
    EXTJSON_WRAPPERS.includes?(key)
  end
  def promote_relaxed_ints(json : JSON::Any) : JSON::Any
    if h = json.as_h?
      if h.size == 1
        key = h.first_key
        return json if extjson_wrapper?(key)
      end
      promoted = Hash(String, JSON::Any).new(initial_capacity: h.size)
      h.each { |k, v| promoted[k] = promote_relaxed_ints(v) }
      JSON::Any.new(promoted)
    elsif a = json.as_a?
      JSON::Any.new(a.map { |v| promote_relaxed_ints(v) })
    elsif i = json.as_i64?
      if i >= Int32::MIN && i <= Int32::MAX
        JSON::Any.new({"$numberInt" => JSON::Any.new(i.to_s)})
      else
        JSON::Any.new({"$numberLong" => JSON::Any.new(i.to_s)})
      end
    else
      json
    end
  end

  def json_to_bson(json : JSON::Any) : BSON
    BSON.from_json(promote_relaxed_ints(json).to_json)
  end

  def write_concern(json : JSON::Any) : Mongo::WriteConcern
    hash = json.as_h
    w_json = hash["w"]?
    w_val = if w_json
              if s = w_json.as_s?
                s
              elsif i = w_json.as_i?
                i
              elsif i = w_json.as_i64?
                i.to_i32
              elsif (h = w_json.as_h?) && (n = h["$numberInt"]? || h["$numberLong"]?)
                n.as_s.to_i32
              end
            end
    j_val = (hash["j"]? || hash["journal"]?).try(&.as_bool)
    wt_json = hash["wtimeoutMS"]? || hash["wtimeout"]? || hash["wTimeoutMS"]?
    wt_val = if wt_json
               if i = wt_json.as_i64?
                 i
               elsif i = wt_json.as_i?
                 i.to_i64
               elsif (h = wt_json.as_h?) && (n = h["$numberInt"]? || h["$numberLong"]?)
                 n.as_s.to_i64
               end
             end
    Mongo::WriteConcern.new(j: j_val, w: w_val, w_timeout: wt_val)
  end

  def read_concern(json : JSON::Any) : Mongo::ReadConcern
    Mongo::ReadConcern.from_bson(BSON.from_json(json.to_json))
  end

  def read_preference(json : JSON::Any) : Mongo::ReadPreference
    Mongo::ReadPreference.from_bson(BSON.from_json(json.to_json))
  end
end
