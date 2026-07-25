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
end
