class Mongo::Collection
  # This is a convenience method for creating a single index.
  #
  # See: `create_indexes`
  def create_index(
    keys,
    *,
    options = NamedTuple.new,
    commit_quorum : (Int32 | String)? = nil,
    max_time_ms : Int64? = nil,
    write_concern : WriteConcern? = nil,
    session : Session::ClientSession? = nil,
  ) : Commands::CreateIndexes::Result?
    self.create_indexes(
      models: [{
        keys:    keys,
        options: options,
      }],
      commit_quorum: commit_quorum,
      max_time_ms: max_time_ms,
      write_concern: write_concern,
      session: session
    )
  end

  # Creates multiple indexes in the collection.
  #
  # NOTE: [for more details, please check the official documentation](https://docs.mongodb.com/manual/reference/command/createIndexes/).
  def create_indexes(
    models : Array,
    *,
    commit_quorum : (Int32 | String)? = nil,
    max_time_ms : Int64? = nil,
    write_concern : WriteConcern? = nil,
    session : Session::ClientSession? = nil,
  ) : Commands::CreateIndexes::Result?
    indexes = models.map { |item|
      if item.is_a? BSON
        keys = item["keys"].as(BSON)
        options = item["options"]?.try(&.as(BSON)) || BSON.new
        unless options.["name"]?
          index_name = String.build do |io|
            keys.join(io, "_") { |(k, v), io| io << k << '_' << v }
          end
          options.append(name: index_name)
        end
        BSON.new({key: keys}).append(options)
      else
        index_model = Index::Model.new(item["keys"], Index::Options.new(**item["options"]))
        index_model.options.name ||= String.build do |io|
          index_model.keys.join(io, "_") { |(k, v), io| io << k << '_' << v }
        end
        BSON.new({key: index_model.keys}).append(index_model.options.to_bson)
      end
    }
    self.command(Commands::CreateIndexes, indexes: indexes, session: session, options: {
      commit_quorum: commit_quorum,
      max_time_ms:   max_time_ms,
      write_concern: write_concern,
    })
  end

  # Drops a single index from the collection by the index name.
  #
  # See: `drop_indexes`
  def drop_index(name : String, *, max_time_ms : Int64? = nil, write_concern : WriteConcern? = nil, session : Session::ClientSession? = nil) : Commands::Common::BaseResult?
    raise Mongo::Error.new "'*' cannot be used with drop_index as more than one index would be dropped." if name == "*"
    self.command(Commands::DropIndexes, index: name, session: session, options: {
      max_time_ms:   max_time_ms,
      write_concern: write_concern,
    })
  end

  # Drops all indexes in the collection.
  #
  # NOTE: [for more details, please check the official documentation](https://docs.mongodb.com/manual/reference/command/dropIndexes/).
  def drop_indexes(*, max_time_ms : Int64? = nil, write_concern : WriteConcern? = nil, session : Session::ClientSession? = nil) : Commands::Common::BaseResult?
    self.command(Commands::DropIndexes, index: "*", session: session, options: {
      max_time_ms:   max_time_ms,
      write_concern: write_concern,
    })
  end

  # Gets index information for all indexes in the collection.
  #
  # NOTE: [for more details, please check the official documentation](https://docs.mongodb.com/manual/reference/command/listIndexes/).
  def list_indexes(session : Session::ClientSession? = nil) : Mongo::Cursor?
    result = self.command(Commands::ListIndexes, session: session) { |result|
      Cursor.new(@database.client, result, session: session)
    }
    raise Mongo::Error.new("Command failed to return a result") unless result
    result
  end
end
