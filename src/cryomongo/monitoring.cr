# Provides runtime information about commands to any 3rd party APM library as well internal driver use, such as logging.
#
# ```
# client = Mongo::Client.new
#
# subscription = client.subscribe_commands { |event|
#   case event
#   when Mongo::Monitoring::Commands::CommandStartedEvent
#     Log.info { "COMMAND.#{event.command_name} #{event.address} STARTED: #{event.command.to_json}" }
#   when Mongo::Monitoring::Commands::CommandSucceededEvent
#     Log.info { "COMMAND.#{event.command_name} #{event.address} COMPLETED: #{event.reply.to_json} (#{event.duration}s)" }
#   when Mongo::Monitoring::Commands::CommandFailedEvent
#     Log.info { "COMMAND.#{event.command_name} #{event.address} FAILED: #{event.failure.inspect} (#{event.duration}s)" }
#   end
# }
#
# client.unsubscribe_commands(subscription)
# ```
module Mongo::Monitoring
  enum Type
    Commands
    SDAM
    CMAP
  end

  # Abstract base class for all monitoring events.
  abstract struct Event
  end

  # Provides an observable interface for the `Mongo::Client`.
  class Observable(T)
    @observable_lock = Sync::Mutex.new
    @subscribers : Set(T -> Nil) = Set(T -> Nil).new

    def broadcast(event : T)
      @observable_lock.synchronize {
        @subscribers.each &.call(event)
      }
    end

    def subscribe(&callback : T -> Nil) : T -> Nil
      @observable_lock.synchronize {
        @subscribers.add(callback)
      }
      callback
    end

    def unsubscribe(callback : T -> Nil) : Nil
      @observable_lock.synchronize {
        @subscribers.delete(callback)
      }
    end

    def has_subscribers?
      @observable_lock.synchronize {
        !@subscribers.empty?
      }
    end
  end

  module Commands
    # Contains common event fields.
    abstract struct Event < Mongo::Monitoring::Event
      macro inherited
        # Returns the command name.
        getter command_name : String
        # Returns the driver generated request id.
        getter request_id : Int64
        # Returns the driver generated operation id. This is used to link events together such
        # as bulk write operations. OPTIONAL.
        getter operation_id : Int64?
        # Returns the server address.
        getter address : String
      end
    end

    # This event is triggered before sending a command to the server.
    struct CommandStartedEvent < Event
      # Returns the command.
      getter command : BSON
      # Returns the database name.
      getter database_name : String

      # :nodoc:
      def initialize(@command_name, @request_id, @address, @command, @database_name, @operation_id = nil)
      end
    end

    # This event is triggered when a command is successfully acknowledged by the server.
    struct CommandSucceededEvent < Event
      # Returns the execution time of the event in the highest possible resolution for the platform.
      getter duration : Time::Span
      # Returns the command reply.
      getter reply : BSON

      # :nodoc:
      def initialize(@command_name, @request_id, @address, @duration, @reply, @operation_id = nil)
      end
    end

    # This event is triggered when a command is rejected by the server.
    struct CommandFailedEvent < Event
      # Returns the execution time of the event in the highest possible resolution for the platform.
      getter duration : Time::Span
      # Returns the failure.
      getter failure : Exception
      # Returns the command reply.
      getter reply : BSON

      # :nodoc:
      def initialize(@command_name, @request_id, @address, @duration, @failure, @reply, @operation_id = nil)
      end
    end
  end

  module SDAM
    abstract struct Event < Mongo::Monitoring::Event
    end

    struct ServerDescriptionChangedEvent < Event
      getter address : String
      getter previous_description : Mongo::SDAM::ServerDescription
      getter new_description : Mongo::SDAM::ServerDescription

      def initialize(@address, @previous_description, @new_description)
      end
    end

    struct TopologyDescriptionChangedEvent < Event
      getter previous_description : Mongo::SDAM::TopologyDescription
      getter new_description : Mongo::SDAM::TopologyDescription

      def initialize(@previous_description, @new_description)
      end
    end

    struct ServerHeartbeatStartedEvent < Event
      getter address : String
      getter? awaited : Bool

      def initialize(@address, @awaited = false)
      end
    end

    struct ServerHeartbeatSucceededEvent < Event
      getter address : String
      getter duration : Time::Span
      getter reply : BSON
      getter? awaited : Bool

      def initialize(@address, @duration, @reply, @awaited = false)
      end
    end

    struct ServerHeartbeatFailedEvent < Event
      getter address : String
      getter duration : Time::Span
      getter failure : Exception
      getter? awaited : Bool

      def initialize(@address, @duration, @failure, @awaited = false)
      end
    end

    struct TopologyOpeningEvent < Event
    end

    struct TopologyClosedEvent < Event
    end

    struct ServerOpeningEvent < Event
      getter address : String

      def initialize(@address)
      end
    end

    struct ServerClosedEvent < Event
      getter address : String

      def initialize(@address)
      end
    end
  end

  module CMAP
    abstract struct Event < Mongo::Monitoring::Event
    end

    struct PoolClearedEvent < Event
      getter address : String
      getter? interrupt_in_use_connections : Bool

      def initialize(@address, @interrupt_in_use_connections = false)
      end
    end

    struct PoolReadyEvent < Event
      getter address : String

      def initialize(@address)
      end
    end

    struct ConnectionClosedEvent < Event
      getter address : String

      def initialize(@address)
      end
    end

    struct ConnectionCheckedOutEvent < Event
      getter address : String

      def initialize(@address)
      end
    end

    struct ConnectionCheckedInEvent < Event
      getter address : String

      def initialize(@address)
      end
    end

    struct ConnectionCheckOutStartedEvent < Event
      getter address : String

      def initialize(@address)
      end
    end
  end
end
