require "bson"
require "../../messages/op_msg"

module Mongo::Auth::X509
  # Nested hello document uses `db`, not `$db`.
  def self.speculative_document(credentials : Mongo::Credentials) : BSON
    BSON.build do |builder|
      builder["authenticate"] = 1
      builder["mechanism"] = "MONGODB-X509"
      builder["db"] = "$external"
      if username = credentials.username
        builder["user"] = username
      end
    end
  end

  def self.authenticate(connection : Mongo::Connection, credentials : Mongo::Credentials)
    bson = BSON.build do |builder|
      builder["authenticate"] = 1
      builder["mechanism"] = "MONGODB-X509"
      builder["$db"] = "$external"
      if username = credentials.username
        builder["user"] = username
      end
    end

    request = Messages::OpMsg.new(bson)
    connection.send(request, "authenticate")
    response = connection.receive

    if error = response.error?
      raise error
    end
  end
end
