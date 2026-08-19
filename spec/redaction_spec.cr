require "./spec_helper"

describe Mongo::Monitoring::Redact do
  it "marks authenticate and saslStart as sensitive" do
    Mongo::Monitoring::Redact.sensitive?("authenticate").should be_true
    Mongo::Monitoring::Redact.sensitive?("saslStart").should be_true
    Mongo::Monitoring::Redact.sensitive?("createUser").should be_true
    Mongo::Monitoring::Redact.sensitive?("find").should be_false
  end

  it "marks hello with speculativeAuthenticate as sensitive" do
    body = BSON.new({"hello" => 1, "speculativeAuthenticate" => {"saslStart" => 1}})
    Mongo::Monitoring::Redact.sensitive?("hello", body).should be_true
    Mongo::Monitoring::Redact.sensitive?("hello", BSON.new({"hello" => 1})).should be_false
    Mongo::Monitoring::Redact.sensitive?("isMaster", body).should be_true
  end

  it "replaces a sensitive command body with an empty document" do
    body = BSON.new({"authenticate" => 1, "pwd" => "secret"})
    Mongo::Monitoring::Redact.body("authenticate", body).should eq Mongo::Monitoring::Redact::EMPTY
    Mongo::Monitoring::Redact.body("ping", BSON.new({"ping" => 1})).should eq BSON.new({"ping" => 1})
  end

  it "redacts command failure messages" do
    error = Mongo::Error::Command.new(18, "AuthenticationFailed", "bad password", nil)
    redacted = Mongo::Monitoring::Redact.failure("saslStart", error)
    redacted.should be_a(Mongo::Error::Command)
    if redacted.is_a?(Mongo::Error::Command)
      redacted.message.should eq "REDACTED"
      redacted.code.should eq 18
      redacted.code_name.should eq "AuthenticationFailed"
    end
  end
end
