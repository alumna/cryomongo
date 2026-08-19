require "./spec_helper"

describe Mongo::Handshake do
  it "builds driver, os, platform, and backpressure-ready metadata" do
    doc = Mongo::Handshake.client_document("my-app")
    app = doc["application"].as(BSON)
    app["name"].should eq "my-app"
    driver = doc["driver"].as(BSON)
    driver["name"].should eq "cryomongo"
    driver["version"].should eq Mongo::VERSION
    os = doc["os"].as(BSON)
    os["type"].should eq Mongo::Handshake::OS_TYPE
    os["architecture"].should eq Mongo::Handshake::OS_ARCH
    doc["platform"].as(String).starts_with?("Crystal ").should be_true
    doc.size.should be <= Mongo::Handshake::MAX_CLIENT_BYTES
  end

  it "rejects an appname longer than 128 bytes" do
    expect_raises(Mongo::Error) do
      Mongo::Handshake.client_document("a" * 129)
    end
  end

  it "appends wrapping library names with |" do
    extra = [Mongo::Handshake::DriverInfo.new("framework", "2.0", "Framework Platform")]
    doc = Mongo::Handshake.client_document(nil, extra: extra)
    driver = doc["driver"].as(BSON)
    driver["name"].should eq "cryomongo|framework"
    driver["version"].as(String).includes?("|2.0").should be_true
    doc["platform"].as(String).includes?("Framework Platform").should be_true
  end

  it "rejects driver info that contains |" do
    expect_raises(Mongo::Error) do
      Mongo::Handshake::DriverInfo.new("bad|name")
    end
  end
end
