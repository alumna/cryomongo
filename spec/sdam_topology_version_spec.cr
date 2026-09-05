require "./spec_helper"

private def tv(counter : Int, pid = "000000000000000000000001") : BSON
  BSON.build do |b|
    b["processId"] = BSON::ObjectId.new(pid)
    b["counter"] = counter.to_i64
  end
end

private def desc(type : Mongo::SDAM::ServerDescription::ServerType, counter : Int? = nil) : Mongo::SDAM::ServerDescription
  d = Mongo::SDAM::ServerDescription.new("a:27017")
  d.type = type
  d.topology_version = tv(counter) if counter
  d
end

describe Mongo::SDAM::TopologyVersion do
  it "treats a missing topologyVersion as newer" do
    Mongo::SDAM::TopologyVersion.compare(nil, tv(1)).should eq 1
    Mongo::SDAM::TopologyVersion.compare(tv(1), nil).should eq 1
  end

  it "orders the same processId by counter" do
    Mongo::SDAM::TopologyVersion.compare(tv(1), tv(2)).should eq 1
    Mongo::SDAM::TopologyVersion.compare(tv(2), tv(1)).should eq -1
    Mongo::SDAM::TopologyVersion.compare(tv(1), tv(1)).should eq 0
  end

  it "reads an Int32 counter without raising" do
    doc = BSON.build do |b|
      b["processId"] = BSON::ObjectId.new("000000000000000000000001")
      b["counter"] = 1
    end
    Mongo::SDAM::TopologyVersion.counter(doc).should eq 1_i64
    Mongo::SDAM::TopologyVersion.compare(doc, tv(1)).should eq 0
  end

  it "marks Unknown on equal TV while the server is still Primary" do
    current = desc(:rs_primary, 2)
    Mongo::SDAM::TopologyVersion.application_error_stale?(current, tv(2)).should be_false
  end

  it "keeps equal TV stale after Unknown or a new replica-set role" do
    Mongo::SDAM::TopologyVersion.application_error_stale?(desc(:unknown, 2), tv(2)).should be_true
    Mongo::SDAM::TopologyVersion.application_error_stale?(desc(:rs_secondary, 2), tv(2)).should be_true
  end

  it "still ignores a strictly older application error" do
    Mongo::SDAM::TopologyVersion.application_error_stale?(desc(:rs_primary, 2), tv(1)).should be_true
  end
end
