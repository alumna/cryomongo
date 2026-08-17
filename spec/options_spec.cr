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
end
