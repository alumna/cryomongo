require "json"
require "bson"

module Mongo::Unified::Matcher
  extend self

  class Mismatch < Exception
  end

  def match!(expected : JSON::Any, actual : JSON::Any, registry : Registry? = nil)
    unless matches?(expected, actual, registry)
      raise Mismatch.new("TEST_FAILED: mismatch at $: expected #{expected.inspect}, got #{actual.inspect}")
    end
  end

  def matches?(expected : JSON::Any, actual : JSON::Any, registry : Registry? = nil, extra_keys : Bool = true) : Bool
    if (h = expected.as_h?) && special?(h)
      return match_special?(h, actual, registry, extra_keys)
    end

    if (en = as_number(expected)) && (an = as_number(actual))
      return en == an
    end

    expected_h = expected.as_h?
    actual_h = actual.as_h?
    if expected_h && actual_h
      if expected_h.has_key?("$date") && actual_h.has_key?("$date")
        return date_ms(expected_h["$date"]) == date_ms(actual_h["$date"])
      end
      if expected_h.has_key?("$oid") && actual_h.has_key?("$oid")
        return expected_h["$oid"] == actual_h["$oid"]
      end
    end

    if expected_h = expected.as_h?
      return false unless actual_h = actual.as_h?
      expected_h.each do |key, exp_val|
        next if key == "$$unsetOrMatches" # handled in special?
        act_val = actual_h[key]?
        if exp_val.as_h? && special?(exp_val.as_h) && exp_val.as_h.has_key?("$$exists")
          return false unless match_special?(exp_val.as_h, act_val || JSON::Any.new(nil), registry, extra_keys)
        elsif act_val.nil?
          # Extra expected key: allow if $$unsetOrMatches wraps it
          if (inner = exp_val.as_h?) && inner.has_key?("$$unsetOrMatches")
            next
          end
          return false
        else
          return false unless matches?(exp_val, act_val, registry, extra_keys)
        end
      end
      unless extra_keys
        actual_h.each_key do |key|
          return false unless expected_h.has_key?(key)
        end
      end
      true
    elsif expected_a = expected.as_a?
      return false unless actual_a = actual.as_a?
      return false unless expected_a.size == actual_a.size
      expected_a.each_with_index do |exp_el, i|
        return false unless matches?(exp_el, actual_a[i], registry, extra_keys)
      end
      true
    else
      values_equal?(expected, actual)
    end
  end

  def documents_match?(expected_docs : Array(JSON::Any), actual_docs : Array(BSON)) : Bool
    return false unless expected_docs.size == actual_docs.size
    expected_docs.each_with_index do |expected, i|
      actual_json = JSON.parse(actual_docs[i].to_canonical_extjson)
      return false unless matches?(expected, actual_json)
    end
    true
  end

  # UTF heartbeat events: awaited is optional. Empty `{}` matches any.
  def heartbeat_awaited?(actual : Bool, expected : JSON::Any) : Bool
    if raw = expected["awaited"]?
      actual == raw.as_bool
    else
      true
    end
  end

  private def special?(h : Hash(String, JSON::Any)) : Bool
    h.size == 1 && h.keys.first.starts_with?("$$")
  end

  private def match_special?(h : Hash(String, JSON::Any), actual : JSON::Any, registry : Registry? = nil, extra_keys : Bool = true) : Bool
    op = h.keys.first
    operand = h[op]
    case op
    when "$$exists"
      exists = operand.as_bool
      present = !actual.raw.nil?
      exists == present
    when "$$type"
      types = operand.as_a? || [operand]
      types.any? { |t| type_matches?(t.as_s, actual) }
    when "$$unsetOrMatches"
      actual.raw.nil? || matches?(operand, actual, registry, extra_keys)
    when "$$matchesHexBytes"
      actual_s = actual.as_s?
      expected_s = operand.as_s?
      !!(actual_s && expected_s && actual_s.downcase == expected_s.downcase)
    when "$$sessionLsid"
      return false unless registry
      session = registry.sessions[operand.as_s]?
      return false unless session
      matches?(json_from(session.session_id.to_bson), actual, registry, extra_keys)
    when "$$matchesEntity"
      return false unless registry
      entity = registry.entities[operand.as_s]?
      return false unless entity
      matches?(json_from(entity), actual, registry, extra_keys)
    when "$$lte"
      numeric_compare(actual, operand) { |a, b| a <= b }
    when "$$gte"
      numeric_compare(actual, operand) { |a, b| a >= b }
    when "$$lt"
      numeric_compare(actual, operand) { |a, b| a < b }
    when "$$gt"
      numeric_compare(actual, operand) { |a, b| a > b }
    when "$$matchAsDocument"
      str = actual.as_s?
      return false unless str
      parsed = JSON.parse(str)
      matches?(operand, parsed, registry, false)
    when "$$matchAsRoot"
      matches?(operand, actual, registry, true)
    else
      # Unknown operator: fail closed so we do not silently pass.
      false
    end
  rescue JSON::ParseException
    false
  end

  private def numeric_compare(actual : JSON::Any, operand : JSON::Any, &) : Bool
    a = as_number(actual)
    b = as_number(operand)
    return false unless a && b
    yield a, b
  end

  private def as_number(value : JSON::Any) : Float64?
    if n = value.as_i?
      n.to_f64
    elsif n = value.as_i64?
      n.to_f64
    elsif n = value.as_f?
      n
    elsif h = value.as_h?
      if v = h["$numberLong"]?
        v.as_s.to_f64
      elsif v = h["$numberInt"]?
        v.as_s.to_f64
      elsif v = h["$numberDouble"]?
        v.as_s.to_f64
      elsif v = h["$numberDecimal"]?
        v.as_s.to_f64
      end
    end
  end

  private def type_matches?(type : String, actual : JSON::Any) : Bool
    raw = actual.raw
    case type
    when "double"                  then raw.is_a?(Float64) || (raw.is_a?(Hash) && actual.as_h.has_key?("$numberDouble"))
    when "string"                  then raw.is_a?(String)
    when "object"                  then raw.is_a?(Hash)
    when "array"                   then raw.is_a?(Array)
    when "binData", "binary"       then raw.is_a?(Hash) && actual.as_h.has_key?("$binary")
    when "undefined"               then raw.nil?
    when "objectId", "oid"         then raw.is_a?(Hash) && actual.as_h.has_key?("$oid")
    when "bool", "boolean"         then raw.is_a?(Bool)
    when "date"                    then raw.is_a?(Hash) && actual.as_h.has_key?("$date")
    when "null"                    then raw.nil?
    when "regex"                   then raw.is_a?(Hash) && actual.as_h.has_key?("$regularExpression")
    when "int", "int32"            then raw.is_a?(Int32) || (raw.is_a?(Int64) && raw.as(Int64) >= Int32::MIN && raw.as(Int64) <= Int32::MAX) || (raw.is_a?(Hash) && (actual.as_h.has_key?("$numberInt") || actual.as_h.has_key?("$numberLong")))
    when "long", "int64"           then raw.is_a?(Int) || (raw.is_a?(Hash) && (actual.as_h.has_key?("$numberLong") || actual.as_h.has_key?("$numberInt")))
    when "decimal", "decimal128"   then raw.is_a?(Hash) && actual.as_h.has_key?("$numberDecimal")
    when "timestamp"               then raw.is_a?(Hash) && actual.as_h.has_key?("$timestamp")
    when "number"                  then raw.is_a?(Number) || (raw.is_a?(Hash) && (actual.as_h.has_key?("$numberLong") || actual.as_h.has_key?("$numberDecimal") || actual.as_h.has_key?("$numberInt") || actual.as_h.has_key?("$numberDouble")))
    else
      false
    end
  end

  private def values_equal?(expected : JSON::Any, actual : JSON::Any) : Bool
    if (en = as_number(expected)) && (an = as_number(actual))
      return en == an
    end

    eh = expected.as_h?
    ah = actual.as_h?
    if eh && ah
      if eh.has_key?("$oid") && ah.has_key?("$oid")
        return eh["$oid"] == ah["$oid"]
      end
      if eh.has_key?("$date") && ah.has_key?("$date")
        return date_ms(eh["$date"]) == date_ms(ah["$date"])
      end
    end

    expected == actual
  end

  # Canonical ExtJSON uses `{"$numberLong": "..."}`. Relaxed ExtJSON uses an ISO string.
  private def date_ms(value : JSON::Any) : Int64?
    if s = value.as_s?
      Time.parse_rfc3339(s).to_unix_ms
    elsif h = value.as_h?
      if v = h["$numberLong"]?
        v.as_s.to_i64
      end
    elsif n = value.as_i64?
      n
    end
  rescue
    nil
  end

  def json_from(value) : JSON::Any
    case value
    when JSON::Any
      value
    when Nil
      JSON::Any.new(nil)
    when Bool
      JSON::Any.new(value)
    when Int32
      JSON::Any.new(value.to_i64)
    when Int64
      JSON::Any.new(value)
    when Float64
      JSON::Any.new(value)
    when String
      JSON::Any.new(value)
    when Slice(UInt8)
      JSON::Any.new(value.hexstring)
    when BSON::Binary
      wrap = BSON.build { |bson| bson["v"] = value }
      JSON.parse(wrap.to_canonical_extjson)["v"]
    when BSON
      JSON.parse(value.to_canonical_extjson)
    when BSON::Value
      wrap = BSON.new
      wrap["v"] = value
      JSON.parse(wrap.to_canonical_extjson).as_h["v"]
    when Array
      JSON::Any.new(value.map { |v| json_from(v).as(JSON::Any) })
    when Hash
      JSON::Any.new(value.transform_values { |v| json_from(v) })
    else
      JSON::Any.new(nil)
    end
  end
end
