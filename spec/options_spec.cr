require "./spec_helper"

describe Mongo::SRV do
  it "accepts a target that shares the parent domain" do
    Mongo::SRV.valid_target?("a.example.com", "srv.example.com").should be_true
  end

  it "rejects a target from another domain" do
    Mongo::SRV.valid_target?("evil.other.com", "srv.example.com").should be_false
  end

  it "limits hosts with srvMaxHosts using a shuffle" do
    hosts = [
      Mongo::SRV::Host.new("a.example.com:27017", 60.seconds),
      Mongo::SRV::Host.new("b.example.com:27017", 60.seconds),
      Mongo::SRV::Host.new("c.example.com:27017", 60.seconds),
    ]
    limited = Mongo::SRV.limit_hosts(hosts, 2)
    limited.size.should eq 2
    Mongo::SRV.limit_hosts(hosts, 0).size.should eq 3
  end
end

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

  it "parses timeoutMS as a span" do
    _, options, _, _ = Mongo::URI.parse("mongodb://localhost/?timeoutMS=2500", Mongo::Options.new)
    options.timeout.should eq 2500.milliseconds
  end

  it "parses srvMaxHosts and srvServiceName on mongodb+srv URIs after DNS" do
    # Validation of the names themselves does not need DNS. A non-srv URI is rejected.
    expect_raises(Mongo::Error, /srvMaxHosts/) do
      Mongo::URI.parse("mongodb://localhost/?srvMaxHosts=2", Mongo::Options.new)
    end
    expect_raises(Mongo::Error, /srvServiceName/) do
      Mongo::URI.parse("mongodb://localhost/?srvServiceName=custom", Mongo::Options.new)
    end
  end

  it "rejects loadBalanced=true with multiple hosts" do
    expect_raises(Mongo::Error, /loadBalanced/) do
      Mongo::URI.parse("mongodb://localhost:27017,localhost:27018/?loadBalanced=true", Mongo::Options.new)
    end
  end

  it "rejects loadBalanced=true with replicaSet" do
    expect_raises(Mongo::Error, /loadBalanced/) do
      Mongo::URI.parse("mongodb://localhost/?loadBalanced=true&replicaSet=rs0", Mongo::Options.new)
    end
  end

  it "rejects loadBalanced=true with directConnection=true" do
    expect_raises(Mongo::Error, /loadBalanced/) do
      Mongo::URI.parse("mongodb://localhost/?loadBalanced=true&directConnection=true", Mongo::Options.new)
    end
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

  it "keeps only the first host" do
    mongodb_uri_one_host("mongodb://localhost:27017,localhost:27016/?replicaSet=rs0").should eq(
      "mongodb://localhost:27017/?replicaSet=rs0"
    )
    mongodb_uri_one_host("mongodb://localhost:27017").should eq("mongodb://localhost:27017")
  end
end
