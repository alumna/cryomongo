class Mongo::Collection
  # Compact Queryable Encryption metadata for this collection.
  # Needs auto-encryption so libmongocrypt can add `compactionTokens`.
  #
  # NOTE: This is not the storage `compact` command.
  def compact_structured_encryption_data(
    *,
    session : Session::ClientSession? = nil,
    timeout_ms : Int64? = nil,
  ) : Commands::Common::BaseResult?
    self.command(Commands::CompactStructuredEncryptionData, session: session, timeout_ms: timeout_ms)
  end
end
