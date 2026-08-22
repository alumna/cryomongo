require "bson"
require "../commands"

# *hello* returns a document that describes the role of the mongod instance.
#
# NOTE: [for more details, please check the official MongoDB documentation](https://www.mongodb.com/docs/manual/reference/command/hello/).
module Mongo::Commands::Hello
  extend Command
  extend self

  # Returns a pair of OP_MSG body and sequences associated with the command and arguments.
  # *client* is the handshake metadata document. Omit it on later heartbeats.
  def command(appname : String? = nil, legacy : Bool = false, *, client : BSON? = nil, load_balanced : Bool = false, compression : Array(String) = [] of String, topology_version : BSON? = nil, max_await_time_ms : Int64? = nil)
    cmd_name = legacy ? "isMaster" : "hello"
    body = BSON.build do |builder|
      builder[cmd_name] = 1
      builder["$db"] = "admin"
      builder["helloOk"] = true
      builder["backpressure"] = "2"
      builder["loadBalanced"] = true if load_balanced
      builder["client"] = client if client
      builder["compression"] = compression
      builder["topologyVersion"] = topology_version if topology_version
      builder["maxAwaitTimeMS"] = max_await_time_ms if max_await_time_ms
    end
    {body, nil}
  end

  Common.result(Result) {
    property ismaster : Bool = false
    property isWritablePrimary : Bool = false
    property max_bson_object_size : Int32 = 16 * 1024 * 1024
    property max_message_size_bytes : Int32 = 48_000_000
    property max_write_batch_size : Int32 = 100_000
    property local_time : (Time | Int64)?
    property logical_session_timeout_minutes : Int32?
    property connection_id : Int32?
    property min_wire_version : Int32 = 0
    property max_wire_version : Int32 = 0
    property read_only : Bool?
    property compression : Array(String)?
    property sasl_supported_mechs : Array(String)?

    # Sharded instances
    property msg : String?

    # Replica sets
    property hosts : Array(String)?
    property set_name : String?
    property set_version : Int32?
    property secondary : Bool?
    property passives : Array(String)?
    property arbiters : Array(String)?
    property primary : String?
    property arbiter_only : Bool?
    property passive : Bool?
    property hidden : Bool?
    property tags : BSON?
    property me : String?
    property election_id : BSON::ObjectId?
    # lastWrite from hello. DateTime fields become Time through Serializable.
    Common.result(LastWrite, root: false) {
      property last_write_date : Time?
      property op_time : BSON?
    }
    property last_write : LastWrite?
    property isreplicaset : Bool?
    property topology_version : BSON?
    property helloOk : Bool?
    property serviceId : BSON::ObjectId?
  }

  # Transforms the server result.
  def result(bson : BSON)
    Result.from_bson(bson)
  end
end
