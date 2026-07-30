require "bson"
require "../../messages/op_msg"

module Mongo::Auth::X509
  def self.authenticate(connection : Mongo::Connection, credentials : Mongo::Credentials)
    bson = BSON.new({
      authenticate: 1,
      mechanism:    "MONGODB-X509",
      "$db":        "$external",
    })

    if username = credentials.username
      bson["user"] = username
    end

    request = Messages::OpMsg.new(bson)
    connection.send(request, "authenticate")
    response = connection.receive

    if error = response.error?
      raise error
    end
  end
end
