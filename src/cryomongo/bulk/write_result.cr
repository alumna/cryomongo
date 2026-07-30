class Mongo::Bulk
  # An aggregated result of the server replies.
  class WriteResult
    property n_inserted : Int32 = 0
    property n_matched : Int32 = 0
    property n_modified : Int32 = 0
    property n_removed : Int32 = 0
    property n_upserted : Int32 = 0
    property upserted : Array(Commands::Common::Upserted) = [] of Commands::Common::Upserted
    property write_errors : Array(Commands::Common::WriteError) = [] of Commands::Common::WriteError
    property write_concern_errors : Array(Commands::Common::WriteConcernError) = [] of Commands::Common::WriteConcernError
  end
end
