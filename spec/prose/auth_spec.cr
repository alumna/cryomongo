require "../spec_helper"

describe "Auth live" do
  uri = ENV["MONGODB_URI"]? || ""
  has_creds = uri.includes?("@")

  it "authenticates with default SCRAM (speculative SHA-256)" do
    pending!("needs credentials in MONGODB_URI") unless has_creds
    client = Mongo::Client.new(mongodb_uri_with(uri, "serverSelectionTimeoutMS=5000"))
    begin
      reply = client.command(Mongo::Commands::Ping)
      reply.try(&.ok).should eq 1.0
    ensure
      client.close
    end
  end

  it "authenticates with SCRAM-SHA-256 when the URI asks for it" do
    pending!("needs credentials in MONGODB_URI") unless has_creds
    client = Mongo::Client.new(mongodb_uri_with(uri, "authMechanism=SCRAM-SHA-256&serverSelectionTimeoutMS=5000"))
    begin
      reply = client.command(Mongo::Commands::Ping)
      reply.try(&.ok).should eq 1.0
    ensure
      client.close
    end
  end

  it "authenticates with SCRAM-SHA-1 when the URI asks for it" do
    pending!("needs credentials in MONGODB_URI") unless has_creds
    client = Mongo::Client.new(mongodb_uri_with(uri, "authMechanism=SCRAM-SHA-1&serverSelectionTimeoutMS=5000"))
    begin
      reply = client.command(Mongo::Commands::Ping)
      reply.try(&.ok).should eq 1.0
    ensure
      client.close
    end
  end

  it "authenticates with MONGODB-X509" do
    x509 = ENV["MONGODB_X509_URI"]?
    pending!("needs TLS client certs (MONGODB_X509_URI)") unless x509
    client = Mongo::Client.new(x509)
    begin
      reply = client.command(Mongo::Commands::Ping)
      reply.try(&.ok).should eq 1.0
    ensure
      client.close
    end
  end

  it "authenticates with PLAIN" do
    plain = ENV["MONGODB_PLAIN_URI"]?
    pending!("needs LDAP / PLAIN (MONGODB_PLAIN_URI)") unless plain
    client = Mongo::Client.new(plain)
    begin
      reply = client.command(Mongo::Commands::Ping)
      reply.try(&.ok).should eq 1.0
    ensure
      client.close
    end
  end
end
