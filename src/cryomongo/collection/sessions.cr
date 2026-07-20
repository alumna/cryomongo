class Mongo::Collection
  private struct SessionProxy
    def initialize(@collection : Collection, @session : Session::ClientSession); end

    macro method_missing(call)
      @collection.{{call.name.id}}({% for arg in call.args %}{{arg}},{% end %}session: @session)
    end
  end

  # Initialize a session that has the same lifetime as the block.
  #
  # - First block argument is a reflection of the Collection instance with the *session* method argument already provided.
  # - Second block argument is the ClientSession.
  #
  # ```
  # client = Mongo::Client.new
  # collection = client["db"]["coll"]
  #
  # collection.with_session(causal_consistency: true) do |collection, session|
  #   5.times { |idx|
  #     # No need to provide: `session: session`.
  #     collection.insert_one({number: idx})
  #     collection.find_one({number: idx})
  #   }
  # end
  # ```
  def with_session(**args, &block)
    session = @database.client.start_session(**args)
    yield SessionProxy.new(self, session), session
  ensure
    session.try &.end
  end
end
