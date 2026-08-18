require "./error"

# :nodoc:
module Mongo::Tools
  extend self

  # Write one field into a BSON builder. Matches `BSON#[]=` (`to_bson` when present).
  def write_bson_field(builder : BSON::Builder, key : String, value) : Nil
    if value.responds_to?(:to_bson)
      builder[key] = value.to_bson
    else
      builder[key] = value
    end
  end

  # Convert a BSON datetime value to `Time`. Decode now returns `BSON::DateTime`.
  def as_time?(value) : Time?
    case value
    when Time
      value
    when BSON::DateTime
      value.to_time?
    else
      nil
    end
  end

  # Merge *init* and *options* with one buffer rebuild. Prefer this over many `[]=`.
  def merge_bson(init, options = nil, skip_nil = true, &block)
    return BSON.new(init) unless options

    bson = BSON.new(init)
    bson.append do |builder|
      options.each { |key, value|
        skip_key = yield nil, key, value
        if skip_key == false && (skip_nil == false || !value.nil?)
          write_bson_field(builder, key.to_s.camelcase(lower: true), value)
        end
      }
    end
    bson
  end

  def merge_bson(init, options = nil, skip_nil = true)
    self.merge_bson(init, options, skip_nil) { false }
  end

  module Initializer
    macro included
      {% verbatim do %}
      def initialize(**args)
        {% for ivar in @type.instance_vars %}
          {% default_value = ivar.default_value %}
          {% if ivar.has_default_value? %}
            %value{ivar} = args["{{ivar.id}}"]?
            @{{ivar.id}} = %value{ivar}.nil? ? {{ default_value }} : %value{ivar}
          {% elsif ivar.type.nilable? %}
            @{{ivar.id}} = args["{{ivar.id}}"]?
          {% else %}
            @{{ivar.id}} = args["{{ivar.id}}"]
          {% end %}
        {% end %}
      end
      {% end %}
    end
  end
end
