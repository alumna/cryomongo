# src/cryomongo/monitoring/sdam.cr
module Mongo::Monitoring::SDAM
  abstract struct Event
    getter topology_id : UInt64

    def initialize(@topology_id)
    end
  end

  struct TopologyOpeningEvent < Event; end

  struct TopologyClosedEvent < Event; end

  struct TopologyDescriptionChangedEvent < Event
    getter previous_description : Mongo::SDAM::TopologyDescription
    getter new_description : Mongo::SDAM::TopologyDescription

    def initialize(topology_id, @previous_description, @new_description)
      super(topology_id)
    end
  end

  struct ServerOpeningEvent < Event
    getter address : String

    def initialize(topology_id, @address)
      super(topology_id)
    end
  end

  struct ServerClosedEvent < Event
    getter address : String

    def initialize(topology_id, @address)
      super(topology_id)
    end
  end

  struct ServerDescriptionChangedEvent < Event
    getter address : String
    getter previous_description : Mongo::SDAM::ServerDescription
    getter new_description : Mongo::SDAM::ServerDescription

    def initialize(topology_id, @address, @previous_description, @new_description)
      super(topology_id)
    end
  end

  # Monitor hello is about to start. For a new socket this is before connect.
  # Spec connectionId is hostname:port when the language has no wrapper id here.
  struct ServerHeartbeatStartedEvent < Event
    getter address : String
    getter awaited : Bool

    def initialize(topology_id, @address, @awaited)
      super(topology_id)
    end
  end

  # Monitor hello returned ok:1. duration matches RTT when awaited is false.
  struct ServerHeartbeatSucceededEvent < Event
    getter address : String
    getter duration : Time::Span
    getter reply : BSON
    getter awaited : Bool

    def initialize(topology_id, @address, @duration, @reply, @awaited)
      super(topology_id)
    end
  end

  # Monitor hello failed (ok:0 or a socket error). RTT commands do not emit this.
  struct ServerHeartbeatFailedEvent < Event
    getter address : String
    getter duration : Time::Span
    getter failure : Exception
    getter awaited : Bool

    def initialize(topology_id, @address, @duration, @failure, @awaited)
      super(topology_id)
    end
  end
end
