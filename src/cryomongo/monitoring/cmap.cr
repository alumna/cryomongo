# Connection pool events (CMAP). Used by prose tests and UTF waitForEvent.
module Mongo::Monitoring::CMAP
  abstract struct Event
    getter address : String

    def initialize(@address)
    end
  end

  struct PoolClearedEvent < Event
    def initialize(address : String)
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

  struct ConnectionClosedEvent < Event
    getter connection_id : Int64

    def initialize(address : String, @connection_id : Int64)
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

    def initialize(address : String, @connection_id : Int64)
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

    def initialize(address : String, @reason : String)
      super(address)
    end
  end
end
