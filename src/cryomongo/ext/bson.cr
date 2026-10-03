# :nodoc:
class BSON
  # Return a copy with keys from *named_tuple* overriding this document.
  # One builder pass. Do not use many `[]=` calls.
  def copy_with(named_tuple : NamedTuple) : BSON
    BSON.build do |builder|
      self.each { |key, value, code|
        if named_tuple[key]?
          override = named_tuple[key]
          if override.responds_to?(:to_bson)
            builder[key] = override.to_bson
          else
            builder[key] = override
          end
        elsif value.is_a?(BSON) && code.array?
          builder.append_array(key, value)
        else
          builder[key] = value
        end
      }
      named_tuple.each { |key, value|
        key_s = key.to_s
        next if has_key?(key_s)
        if value.responds_to?(:to_bson)
          builder[key_s] = value.to_bson
        else
          builder[key_s] = value
        end
      }
    end
  end
end
