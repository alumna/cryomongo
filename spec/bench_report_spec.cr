require "spec"
require "../bench/timing"
require "../bench/report"

describe "DriverBench report" do
  it "redacts URI user and password" do
    DriverBench::Report.redact_uri("mongodb://alice:s3cret@localhost:27017/?replicaSet=rs0").should eq(
      "mongodb://***:***@localhost:27017/?replicaSet=rs0"
    )
    DriverBench::Report.redact_uri("mongodb://localhost:27017").should eq("mongodb://localhost:27017")
  end

  it "reads topology from the URI" do
    DriverBench::Report.topology_from_uri("mongodb://localhost:27017/?replicaSet=rs0").should eq("replica-set")
    DriverBench::Report.topology_from_uri("mongodb://127.0.0.1:8000/?loadBalanced=true").should eq("load-balanced")
    DriverBench::Report.topology_from_uri("mongodb://localhost:27017,localhost:27016").should eq("multi-host")
    DriverBench::Report.topology_from_uri("mongodb://localhost:27017").should eq("standalone")
  end

  it "treats localhost as the same machine" do
    DriverBench::Report.same_machine?("mongodb://localhost:27017/?replicaSet=rs0").should be_true
    DriverBench::Report.same_machine?("mongodb://example.net:27017").should be_false
  end

  it "builds composites without the extra parallel task" do
    bson = [
      DriverBench::Timing::Result.new("flat bson encode", 1_i64, 8, 0.1, 10.0),
      DriverBench::Timing::Result.new("flat bson decode", 1_i64, 8, 0.1, 20.0),
    ]
    live = [
      DriverBench::Timing::Result.new("find one by id", 1_i64, 8, 0.1, 12.0),
      DriverBench::Timing::Result.new("small insertOne", 1_i64, 8, 0.1, 1.0),
      DriverBench::Timing::Result.new("large insertOne", 1_i64, 8, 0.1, 60.0),
      DriverBench::Timing::Result.new("find many", 1_i64, 8, 0.1, 100.0),
      DriverBench::Timing::Result.new("small insertMany", 1_i64, 8, 0.1, 20.0),
      DriverBench::Timing::Result.new("large insertMany", 1_i64, 8, 0.1, 70.0),
      DriverBench::Timing::Result.new("small collection bulkWrite", 1_i64, 8, 0.1, 30.0),
      DriverBench::Timing::Result.new("large collection bulkWrite", 1_i64, 8, 0.1, 80.0),
      DriverBench::Timing::Result.new("small collection bulkWrite mixed", 1_i64, 8, 0.1, 2.0),
      DriverBench::Timing::Result.new("gridfs upload", 1_i64, 8, 0.1, 200.0),
      DriverBench::Timing::Result.new("gridfs download", 1_i64, 8, 0.1, 400.0),
      DriverBench::Timing::Result.new("parallel small insertMany", 1_i64, 8, 0.1, 999.0),
    ]
    c = DriverBench::Report.composites(bson, live)
    c["BSONBench"].should be_close(15.0, 1e-9)
    c["SingleBench"].should be_close((12.0 + 1.0 + 60.0) / 3.0, 1e-9)
    c["ReadBench"].should be_close((12.0 + 100.0 + 400.0) / 3.0, 1e-9)
    write = (1.0 + 60.0 + 20.0 + 70.0 + 30.0 + 80.0 + 2.0 + 200.0) / 8.0
    c["WriteBench"].should be_close(write, 1e-9)
    c["DriverBench"].should be_close((c["ReadBench"] + c["WriteBench"]) / 2.0, 1e-9)
  end
end
