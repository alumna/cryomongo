require "./saslprep"
require "./scram"
require "./x509"
require "./plain"

# :nodoc:
module Mongo::Auth
  enum Mechanism
    ScramSha1
    ScramSha256
    MongodbX509
    MongodbCR
    MongodbAWS
    GssApi
    Plain
  end

  # Wire names use hyphens (`SCRAM-SHA-256`). Crystal enum parse does not.
  def self.parse_mechanism(name : String) : Mechanism
    case name.upcase.gsub(/[-_]/, "")
    when "SCRAMSHA1"
      Mechanism::ScramSha1
    when "SCRAMSHA256"
      Mechanism::ScramSha256
    when "MONGODBX509"
      Mechanism::MongodbX509
    when "PLAIN"
      Mechanism::Plain
    else
      raise Mongo::Error.new("Authentication mechanism not supported: #{name}")
    end
  end
end
