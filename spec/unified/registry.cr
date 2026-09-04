module Mongo::Unified
  class Registry
    property clients = Hash(String, Mongo::Client).new
    property databases = Hash(String, Mongo::Database).new
    property collections = Hash(String, Mongo::Collection).new
    property buckets = Hash(String, Mongo::GridFS::Bucket).new
    property sessions = Hash(String, Mongo::Session::ClientSession).new
    property client_encryptions = Hash(String, Mongo::ClientEncryption).new
    property cursors = Hash(String, Mongo::Cursor).new
    property entities = Hash(String, BSON::Value).new
    property topology_descriptions = Hash(String, Mongo::SDAM::TopologyDescription).new
    property command_events = Hash(String, Array(Mongo::Monitoring::Commands::Event)).new
    property sdam_events = Hash(String, Array(Mongo::Monitoring::SDAM::Event)).new
    property cmap_events = Hash(String, Array(Mongo::Monitoring::CMAP::Event)).new
    property log_messages = Hash(String, Array(Mongo::Logging::Message)).new
    # Monitor, pool, and test fibers all append. Crystal Array is not thread-safe.
    getter events_lock = Sync::Mutex.new

    def command_started_events
      events_lock.synchronize do
        command_events.transform_values { |events|
          events.select(Mongo::Monitoring::Commands::CommandStartedEvent)
        }
      end
    end

    def snapshot_command_events(client_id : String) : Array(Mongo::Monitoring::Commands::Event)
      events_lock.synchronize { (command_events[client_id]? || [] of Mongo::Monitoring::Commands::Event).dup }
    end

    def snapshot_sdam_events(client_id : String) : Array(Mongo::Monitoring::SDAM::Event)
      events_lock.synchronize { (sdam_events[client_id]? || [] of Mongo::Monitoring::SDAM::Event).dup }
    end

    def snapshot_cmap_events(client_id : String) : Array(Mongo::Monitoring::CMAP::Event)
      events_lock.synchronize { (cmap_events[client_id]? || [] of Mongo::Monitoring::CMAP::Event).dup }
    end

    def snapshot_log_messages(client_id : String) : Array(Mongo::Logging::Message)
      events_lock.synchronize { (log_messages[client_id]? || [] of Mongo::Logging::Message).dup }
    end

    def clear_observed_events : Nil
      events_lock.synchronize do
        command_events.each_value(&.clear)
        cmap_events.each_value(&.clear)
        sdam_events.each_value(&.clear)
        log_messages.each_value(&.clear)
      end
    end

    property ignored_command_events = Hash(String, Array(String)).new
    property observed_events = Hash(String, Array(String)).new
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
      # Close encryption before the key-vault client.
      client_encryptions.each_value do |enc|
        enc.close
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
        client_encryptions[object_id]? ||
        raise "Target entity not found: #{object_id}"
    end
  end
end
