require "./spec_helper"

describe "DriverBench BSON sanity" do
  it "encodes and decodes a flat document" do
    doc = BSON.build do |b|
      b["_id"] = BSON::ObjectId.new
      b["s"] = "x" * 80
      b["i"] = 1
      b["l"] = 1_i64
      b["d"] = 1.0
      b["flag"] = true
    end
    bytes = doc.data
    copy = BSON.new(bytes)
    copy["s"].should eq("x" * 80)
    copy["i"].should eq 1
  end
end
