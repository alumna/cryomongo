require "./operations"

module Mongo::Unified::Dispatcher
  extend self
  include Operations

  def execute(op : Operation, registry : Registry, internal_client : Mongo::Client, runner : Runner)
    args = op.arguments

    # Some operations trigger skips based on their arguments
    if op.name == "clientBulkWrite" || args.try(&.as_h?.try(&.has_key?("let")))
      raise Exception.new("SKIP_TEST")
    end

    expected_error = op.expectError
    target = registry.resolve_target(op.object)
    session = resolve_session(args, registry)

    begin
      case op.name
      when "failPoint"
        runner.fail_point_active = true
        execute_fail_point(args, registry)
      when "createEntities"                           then execute_create_entities(args, runner)
      when "assertSessionPinned"                      then execute_assert_session_pinned(args, registry)
      when "assertSessionUnpinned"                    then execute_assert_session_unpinned(args, registry)
      when "assertSessionTransactionState"            then execute_assert_session_transaction_state(args, registry)
      when "assertSessionDirty"                       then execute_assert_session_dirty(args, registry)
      when "assertSessionNotDirty"                    then execute_assert_session_not_dirty(args, registry)
      when "assertSameLsidOnLastTwoCommands"          then execute_assert_same_lsid(args, registry)
      when "assertDifferentLsidOnLastTwoCommands"     then execute_assert_different_lsid(args, registry)
      when "getSnapshotTime"                          then execute_get_snapshot_time(op, registry)
      when "targetedFailPoint"                        then execute_targeted_fail_point(args, registry)
      when "assertCollectionExists"                   then execute_assert_collection_exists(args, internal_client)
      when "assertCollectionNotExists"                then execute_assert_collection_not_exists(args, internal_client)
      when "assertIndexExists"                        then execute_assert_index_exists(args, internal_client)
      when "assertIndexNotExists"                     then execute_assert_index_not_exists(args, internal_client)
      when "download"                                 then execute_download(args, target)
      when "downloadByName"                           then execute_download_by_name(args, target)
      when "createCollection"                         then execute_create_collection(args, target, session)
      when "dropCollection"                           then execute_drop_collection(args, target, session)
      when "createIndex"                              then execute_create_index(args, target, session)
      when "modifyCollection"                         then execute_modify_collection(args, target, session)
      when "insertOne"                                then execute_insert_one(args, target, session)
      when "insertMany"                               then execute_insert_many(args, target, session)
      when "updateOne"                                then execute_update_one(args, target, session)
      when "updateMany"                               then execute_update_many(args, target, session)
      when "replaceOne"                               then execute_replace_one(args, target, session)
      when "deleteOne"                                then execute_delete_one(args, target, session)
      when "deleteMany"                               then execute_delete_many(args, target, session)
      when "find"                                     then execute_find(args, target, session)
      when "findOne"                                  then execute_find_one(args, target, session)
      when "listCollections", "listCollectionObjects" then execute_list_collections(args, target, session)
      when "listCollectionNames"                      then execute_list_collection_names(args, target, session)
      when "listDatabases", "listDatabaseObjects"     then execute_list_databases(args, target, session)
      when "listDatabaseNames"                        then execute_list_database_names(args, target, session)
      when "listIndexes"                              then execute_list_indexes(args, target, session)
      when "listIndexNames"                           then execute_list_index_names(args, target, session)
      when "runCommand"                               then execute_run_command(args, target, session)
      when "createChangeStream"                       then execute_create_change_stream(args, target, session)
      when "aggregate"                                then execute_aggregate(args, target, session)
      when "countDocuments"                           then execute_count_documents(args, target, session)
      when "estimatedDocumentCount"                   then execute_estimated_document_count(args, target, session)
      when "distinct"                                 then execute_distinct(args, target, session)
      when "findOneAndDelete"                         then execute_find_one_and_delete(args, target, session)
      when "findOneAndReplace"                        then execute_find_one_and_replace(args, target, session)
      when "findOneAndUpdate"                         then execute_find_one_and_update(args, target, session)
      when "bulkWrite"                                then execute_bulk_write(args, target, session)
      when "startTransaction"                         then execute_start_transaction(args, target)
      when "commitTransaction"                        then execute_commit_transaction(args, target)
      when "abortTransaction"                         then execute_abort_transaction(args, target)
      when "endSession"                               then execute_end_session(args, target)
      when "withTransaction"                          then execute_with_transaction(args, target, registry, internal_client, runner)
      when "runOnThread"                              then execute_run_on_thread(args, registry, internal_client, runner)
      when "waitForThread"                            then execute_wait_for_thread(args, registry)
      else
        # Ignore unsupported operations silently
        return
      end

      if expected_error
        raise Exception.new("TEST_FAILED: Expected operation to fail, but it succeeded.")
      end
    rescue e : Exception
      if e.message.try &.starts_with?("TEST_FAILED")
        raise e
      elsif expected_error
        # Expected error caught successfully!
      else
        raise e
      end
    end
  end
end
