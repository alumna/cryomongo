require "json"
require "bson"

module Mongo::Unified::Parse
  extend self

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
