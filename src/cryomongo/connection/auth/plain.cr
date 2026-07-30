require "bson"
require "../../messages/op_msg"

module Mongo::Auth::Plain
  def self.authenticate(connection : Mongo::Connection, credentials : Mongo::Credentials)
    source = credentials.source || "$external"
    source = "$external" if source.empty?

    username = credentials.username || raise Mongo::Error.new("Username is required for PLAIN auth")
    password = credentials.password || raise Mongo::Error.new("Password is required for PLAIN auth")
    raise Mongo::Error.new("Username is required for PLAIN auth") if username.empty?

    # The SASL PLAIN payload format is: \0username\0password
    payload = Bytes.new(username.bytesize + password.bytesize + 2)
    payload[0] = 0_u8
    payload[1, username.bytesize].copy_from(username.to_slice)
    payload[1 + username.bytesize] = 0_u8
    payload[2 + username.bytesize, password.bytesize].copy_from(password.to_slice)

    bson = BSON.new({
      saslStart: 1,
      mechanism: "PLAIN",
      payload:   payload,
      "$db":     source,
    })

    request = Messages::OpMsg.new(bson)
    connection.send(request, "saslStart")
    response = connection.receive

    if error = response.error?
      raise error
    end
  end
end
