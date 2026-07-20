module Mongo::Unified
  class Registry
    property clients = Hash(String, Mongo::Client).new
    property databases = Hash(String, Mongo::Database).new
    property collections = Hash(String, Mongo::Collection).new
    property buckets = Hash(String, Mongo::GridFS::Bucket).new
    property sessions = Hash(String, Mongo::Session::ClientSession).new

    def close_all
      clients.each_value(&.close)
    end

    def resolve_target(object_id : String)
      return nil if object_id == "testRunner"

      collections[object_id]? ||
        databases[object_id]? ||
        clients[object_id]? ||
        buckets[object_id]? ||
        sessions[object_id]? ||
        raise "Target entity not found: #{object_id}"
    end
  end
end
