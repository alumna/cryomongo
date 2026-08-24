# Connection pool events (CMAP). Used by prose tests and UTF waitForEvent.
module Mongo::Monitoring::CMAP
  abstract struct Event
    getter address : String

    def initialize(@address)
    end
  end

  struct PoolCreatedEvent < Event
    # User-specified pool options only (CMAP log / cmap-format tests).
    getter options : Hash(String, Int64)

    def initialize(address : String, @options : Hash(String, Int64) = {} of String => Int64)
      super(address)
    end
  end

  # Monitor check found a usable server. Checkout and minPoolSize fill may start.
  struct PoolReadyEvent < Event
    def initialize(address : String)
      super(address)
    end
  end

  struct PoolClearedEvent < Event
    # Load-balanced: only connections with this serviceId were cleared.
    getter service_id : BSON::ObjectId?
    # True when the clear closed in-use sockets (monitor hello timeout).
    getter interrupt_in_use_connections : Bool

    def initialize(address : String, @service_id : BSON::ObjectId? = nil, @interrupt_in_use_connections : Bool = false)
      super(address)
    end
  end

  struct PoolClosedEvent < Event
    def initialize(address : String)
      super(address)
    end
  end

  struct ConnectionCreatedEvent < Event
    getter connection_id : Int64

    def initialize(address : String, @connection_id : Int64)
      super(address)
    end
  end

  # Handshake and auth finished. The socket can be used.
  struct ConnectionReadyEvent < Event
    getter connection_id : Int64
    getter duration : Time::Span

    def initialize(address : String, @connection_id : Int64, @duration : Time::Span = Time::Span.zero)
      super(address)
    end
  end

  struct ConnectionClosedEvent < Event
    getter connection_id : Int64
    # "stale", "idle", "error", or "poolClosed".
    getter reason : String
    getter error : Exception?

    def initialize(address : String, @connection_id : Int64, @reason : String = "error", @error : Exception? = nil)
      super(address)
    end
  end

  struct ConnectionCheckOutStartedEvent < Event
    def initialize(address : String)
      super(address)
    end
  end

  struct ConnectionCheckedOutEvent < Event
    getter connection_id : Int64
    getter duration : Time::Span

    def initialize(address : String, @connection_id : Int64, @duration : Time::Span = Time::Span.zero)
      super(address)
    end
  end

  struct ConnectionCheckedInEvent < Event
    getter connection_id : Int64

    def initialize(address : String, @connection_id : Int64)
      super(address)
    end
  end

  struct ConnectionCheckOutFailedEvent < Event
    getter reason : String
    getter duration : Time::Span
    getter error : Exception?

    def initialize(address : String, @reason : String, @duration : Time::Span = Time::Span.zero, @error : Exception? = nil)
      super(address)
    end
  end
end
