require "json"

# Decide whether a UTF JSON file can run on the current topology.
# Wrong-topology files are not registered as Crystal examples (not pending).
module Mongo::Unified::TopologyFilter
  def self.keep?(path : String, topology : String) : Bool
    json = JSON.parse(File.read(path))
    if reqs = json["runOnRequirements"]?.try(&.as_a)
      return false unless reqs.any? { |req| topology_ok?(req, topology) }
    end
    tests = json["tests"]?.try(&.as_a)
    return true unless tests
    return true if tests.empty?
    tests.any? do |test|
      treqs = test["runOnRequirements"]?.try(&.as_a)
      treqs.nil? || treqs.empty? || treqs.any? { |req| topology_ok?(req, topology) }
    end
  rescue
    true
  end

  private def self.topology_ok?(req : JSON::Any, topology : String) : Bool
    tops = req["topologies"]?.try(&.as_a)
    return true if tops.nil? || tops.empty?
    tops.any? { |item| item.as_s == topology }
  end
end
