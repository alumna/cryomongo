# Redact passwords and other secrets from APM events and Log.trace.
# See the Command Logging and Monitoring spec.
module Mongo::Monitoring::Redact
  extend self

  # Command names compared in lowercase. isMaster / ismaster both match.
  SENSITIVE_COMMANDS = Set{
    "authenticate",
    "saslstart",
    "saslcontinue",
    "getnonce",
    "createuser",
    "updateuser",
    "copydbgetnonce",
    "copydbsaslstart",
    "copydb",
  }

  # Empty document used for redacted command and reply bodies.
  EMPTY = BSON.new

  def sensitive?(command_name : String, body : BSON? = nil) : Bool
    name = command_name.downcase
    return true if SENSITIVE_COMMANDS.includes?(name)
    if (name == "hello" || name == "ismaster") && body
      return true if body.has_key?("speculativeAuthenticate")
    end
    false
  end

  # APM / log copy of a command or reply. Sensitive commands become `{}`.
  def body(command_name : String, document : BSON) : BSON
    sensitive?(command_name, document) ? EMPTY : document
  end

  # Failure text for CommandFailedEvent and failed log lines.
  # Keep code, codeName, and errorLabels. Drop errmsg and other fields.
  def failure(command_name : String, error : Exception, body : BSON? = nil) : Exception
    return error unless sensitive?(command_name, body)
    if error.is_a?(Mongo::Error::Command)
      Mongo::Error::Command.new(
        error.code,
        error.code_name,
        "REDACTED",
        nil,
        error_labels: error.error_labels,
        topology_version: error.topology_version
      )
    elsif error.is_a?(Mongo::Error)
      Mongo::Error.new("REDACTED")
    else
      Exception.new("REDACTED")
    end
  end
end
