require "./monitoring/sdam"
require "./monitoring/redact"
require "./monitoring/cmap"

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
  end

  # Provides an observable interface for the `Mongo::Client`.
  class Observable(T)
    @observable_lock = Sync::Mutex.new
    # Copy-on-write. Subscribe replaces this array. Broadcast reads it without a lock.
    @subscribers : Array(T -> Nil) = [] of T -> Nil
    @subscriber_count = Atomic(Int32).new(0)

    def broadcast(event : T)
      return if @subscriber_count.get == 0
      # Do not dup. The array is never mutated after it is published.
      list = @subscribers
      list.each &.call(event)
    end

    def subscribe(&callback : T -> Nil) : T -> Nil
      @observable_lock.synchronize {
        next_list = @subscribers.dup
        next_list << callback
        @subscribers = next_list
        @subscriber_count.set(next_list.size)
      }
      callback
    end

    def unsubscribe(callback : T -> Nil) : Nil
      @observable_lock.synchronize {
        next_list = @subscribers.dup
        next_list.delete(callback)
        @subscribers = next_list
        @subscriber_count.set(next_list.size)
      }
    end

    def has_subscribers?
      @subscriber_count.get > 0
    end
  end

  module Commands
    # Contains common event fields.
    abstract struct Event
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
        # Driver pool connection id (CMAP).
        getter driver_connection_id : Int64?
        # Server connectionId from hello. Nil until handshake finishes.
        getter server_connection_id : Int64?
      end
    end

    # This event is triggered before sending a command to the server.
    struct CommandStartedEvent < Event
      # Returns the command.
      getter command : BSON
      # Returns the database name.
      getter database_name : String
      # Load-balanced: serviceId from hello on this socket.
      getter service_id : BSON::ObjectId?

      # :nodoc:
      def initialize(@command_name, @request_id, @address, @command, @database_name, @operation_id = nil, @service_id = nil, @driver_connection_id = nil, @server_connection_id = nil)
      end
    end

    # This event is triggered when a command is successfully acknowledged by the server.
    struct CommandSucceededEvent < Event
      # Returns the execution time of the event in the highest possible resolution for the platform.
      getter duration : Time::Span
      # Returns the command reply.
      getter reply : BSON
      # Load-balanced: serviceId from hello on this socket.
      getter service_id : BSON::ObjectId?

      # :nodoc:
      def initialize(@command_name, @request_id, @address, @duration, @reply, @operation_id = nil, @service_id = nil, @driver_connection_id = nil, @server_connection_id = nil)
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
      # Load-balanced: serviceId from hello on this socket.
      getter service_id : BSON::ObjectId?

      # :nodoc:
      def initialize(@command_name, @request_id, @address, @duration, @failure, @reply, @operation_id = nil, @service_id = nil, @driver_connection_id = nil, @server_connection_id = nil)
      end
    end
  end
end
