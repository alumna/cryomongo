module Mongo::Unified
  class Registry
    property clients = Hash(String, Mongo::Client).new
    property databases = Hash(String, Mongo::Database).new
    property collections = Hash(String, Mongo::Collection).new
    property buckets = Hash(String, Mongo::GridFS::Bucket).new
    property sessions = Hash(String, Mongo::Session::ClientSession).new
    property cursors = Hash(String, Mongo::Cursor).new
    property entities = Hash(String, BSON::Value).new
    property topology_descriptions = Hash(String, Mongo::SDAM::TopologyDescription).new
    property command_events = Hash(String, Array(Mongo::Monitoring::Commands::Event)).new
    property sdam_events = Hash(String, Array(Mongo::Monitoring::SDAM::Event)).new
    property cmap_events = Hash(String, Array(Mongo::Monitoring::CMAP::Event)).new
    property log_messages = Hash(String, Array(Mongo::Logging::Message)).new

    def command_started_events
      command_events.transform_values { |events|
        events.select(Mongo::Monitoring::Commands::CommandStartedEvent)
      }
    end

    property ignored_command_events = Hash(String, Array(String)).new
    property threads = Hash(String, Channel(Exception?)).new

    def close_all
      cursors.each_value do |cursor|
        cursor.close
      rescue
      end
      sessions.each_value do |session|
        session.end
      rescue
      end
      clients.each_value(&.close)
    end

    def resolve_target(object_id : String)
      return nil if object_id == "testRunner"

      collections[object_id]? ||
        databases[object_id]? ||
        clients[object_id]? ||
        buckets[object_id]? ||
        sessions[object_id]? ||
        cursors[object_id]? ||
        raise "Target entity not found: #{object_id}"
    end
  end
end
