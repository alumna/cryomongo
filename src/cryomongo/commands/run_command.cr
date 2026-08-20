require "./commands"

# Generic runCommand / runCursorCommand body. The user document is copied so
# driver fields ($db, $readPreference, lsid) do not mutate the caller's BSON.
# Not retryable. Server selection treats it as a read (MayUseSecondary).
# Database and collection read/write concern are not mixed in.
struct Mongo::Commands::RunCommand
  include Command
  include MayUseSecondary

  getter name : String

  def initialize(@name : String)
  end

  # First non-$ key. Used as the APM command name.
  def self.first_key(command : BSON) : String
    command.each do |key, _|
      return key unless key.starts_with?('$')
    end
    "runCommand"
  end

  def self.cursor_result(reply) : Commands::Common::QueryResult
    bson = reply.as?(BSON)
    unless bson && bson["cursor"]?
      raise Mongo::Error.new("Command did not return a cursor")
    end
    Commands::Common::QueryResult.from_bson(bson)
  end

  def command(**args)
    user = args["command_bson"].as(BSON)
    database = args["database"].as(String)
    body = BSON.build do |builder|
      has_db = false
      user.each do |key, value, code|
        has_db = true if key == "$db"
        if value.is_a?(BSON) && code.array?
          builder.append_array(key, value)
        else
          builder[key] = value
        end
      end
      builder["$db"] = database unless has_db
      # $readPreference is only for a non-primary mode (runCommand spec).
      if (opts = args["options"]?) && (rp = opts["read_preference"]?)
        pref = rp.as(Mongo::ReadPreference)
        unless pref.mode == "primary"
          Tools.write_bson_field(builder, "$readPreference", pref)
        end
      end
    end
    {body, nil}
  end

  def result(bson : BSON)
    bson
  end
end
