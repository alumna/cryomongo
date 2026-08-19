require "./spec_helper"

describe Mongo::Options do
  it "parses boolean URI values without regard to case" do
    _, options, _, _ = Mongo::URI.parse("mongodb://localhost/?retryWrites=FALSE&retryReads=True", Mongo::Options.new)
    options.retry_writes.should eq false
    options.retry_reads.should eq true
  end

  it "raises when a boolean URI value is not true or false" do
    expect_raises(Mongo::Error, /invalid boolean value/i) do
      Mongo::URI.parse("mongodb://localhost/?retryWrites=yes", Mongo::Options.new)
    end
  end

  it "sets load_balanced from the loadBalanced URI option" do
    _, options, _, _ = Mongo::URI.parse("mongodb://localhost/?loadBalanced=true", Mongo::Options.new)
    options.load_balanced.should eq true
  end

  it "defaults server_selection_try_once to false" do
    Mongo::Options.new.server_selection_try_once.should eq false
  end

  it "honors serverSelectionTryOnce in the URI" do
    _, options, _, _ = Mongo::URI.parse("mongodb://localhost/?serverSelectionTryOnce=true", Mongo::Options.new)
    options.server_selection_try_once.should eq true
  end

  it "parses maxIdleTimeMS as a span" do
    _, options, _, _ = Mongo::URI.parse("mongodb://localhost/?maxIdleTimeMS=1500", Mongo::Options.new)
    options.max_idle_time.should eq 1500.milliseconds
  end

  it "parses maxAdaptiveRetries from the URI" do
    _, options, _, _ = Mongo::URI.parse("mongodb://localhost/?maxAdaptiveRetries=1", Mongo::Options.new)
    options.max_adaptive_retries.should eq 1
  end

  it "parses options when the delimiting slash is omitted" do
    seeds, options, _, db = Mongo::URI.parse("mongodb://localhost:27017?serverSelectionTimeoutMS=2000", Mongo::Options.new)
    seeds.size.should eq 1
    seeds[0].host.should eq "localhost"
    seeds[0].port.should eq 27017
    options.server_selection_timeout.should eq 2000.milliseconds
    db.should eq ""
  end

  it "parses tls when the delimiting slash is omitted" do
    _, options, _, _ = Mongo::URI.parse("mongodb://example.com?tls=true", Mongo::Options.new)
    options.tls.should eq true
  end
end

describe "mongodb_uri_with" do
  it "inserts /? when the URI has no query" do
    mongodb_uri_with("mongodb://localhost:27017", "serverSelectionTimeoutMS=2000").should eq(
      "mongodb://localhost:27017/?serverSelectionTimeoutMS=2000"
    )
  end

  it "appends with & when the URI already has a query" do
    mongodb_uri_with("mongodb://localhost:27017/?replicaSet=rs0", "serverSelectionTimeoutMS=2000").should eq(
      "mongodb://localhost:27017/?replicaSet=rs0&serverSelectionTimeoutMS=2000"
    )
  end

  it "does not add a second slash when the URI already ends with /" do
    mongodb_uri_with("mongodb://localhost:27017/", "a=1").should eq("mongodb://localhost:27017/?a=1")
  end
end
