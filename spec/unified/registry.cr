module Mongo::Unified
  class ThreadEntity
    getter channel = Channel(Exception?).new

    def run(&block)
      ::spawn do
        begin
          block.call
          @channel.send(nil)
        rescue e : Exception
          @channel.send(e)
        end
      end
    end

    def wait
      if err = @channel.receive
        raise err
      end
    end
  end

  class Registry
    property clients = Hash(String, Mongo::Client).new
    property databases = Hash(String, Mongo::Database).new
    property collections = Hash(String, Mongo::Collection).new
    property buckets = Hash(String, Mongo::GridFS::Bucket).new
    property sessions = Hash(String, Mongo::Session::ClientSession).new
    property threads = Hash(String, ThreadEntity).new
    property entities = Hash(String, BSON::Value | Mongo::SDAM::TopologyDescription).new
    property command_started_events = Hash(String, Array(Mongo::Monitoring::Commands::CommandStartedEvent)).new
    property events = Hash(String, Array(Mongo::Monitoring::Event)).new

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
        threads[object_id]? ||
        raise "Target entity not found: #{object_id}"
    end
  end
end
