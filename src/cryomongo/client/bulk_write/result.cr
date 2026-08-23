# Result and error types for `Mongo::Client#bulk_write`.
module Mongo::ClientBulk
  # Successful insert in verbose results.
  record InsertResult, inserted_id : BSON::Value

  # Successful update or replace in verbose results.
  record UpdateResult, matched_count : Int32, modified_count : Int32, upserted_id : BSON::Value? = nil

  # Successful delete in verbose results.
  record DeleteResult, deleted_count : Int32

  # One write error from the results cursor (`idx` is the original model index).
  record WriteError, index : Int32, code : Int32, message : String, details : BSON? = nil

  # One write concern error from a `bulkWrite` command reply.
  record WriteConcernError, code : Int32, message : String, details : BSON? = nil

  # Summary (and optional verbose maps) for a client `bulkWrite`.
  class WriteResult
    property acknowledged : Bool
    property inserted_count : Int32
    property upserted_count : Int32
    property matched_count : Int32
    property modified_count : Int32
    property deleted_count : Int32
    # Nil when `verbose_results` is false.
    property insert_results : Hash(Int32, InsertResult)?
    property update_results : Hash(Int32, UpdateResult)?
    property delete_results : Hash(Int32, DeleteResult)?

    def initialize(
      @acknowledged : Bool = true,
      @inserted_count = 0,
      @upserted_count = 0,
      @matched_count = 0,
      @modified_count = 0,
      @deleted_count = 0,
      @insert_results : Hash(Int32, InsertResult)? = nil,
      @update_results : Hash(Int32, UpdateResult)? = nil,
      @delete_results : Hash(Int32, DeleteResult)? = nil,
    )
    end

    def self.empty(*, verbose : Bool, acknowledged : Bool = true) : self
      if verbose
        new(
          acknowledged: acknowledged,
          insert_results: {} of Int32 => InsertResult,
          update_results: {} of Int32 => UpdateResult,
          delete_results: {} of Int32 => DeleteResult,
        )
      else
        new(acknowledged: acknowledged)
      end
    end

    def any_success? : Bool
      @inserted_count > 0 || @upserted_count > 0 || @matched_count > 0 ||
        @modified_count > 0 || @deleted_count > 0
    end
  end
end

# Raised when a client `bulkWrite` has write errors, write concern errors, or a top-level error after some writes succeeded.
class Mongo::Error::ClientBulkWrite < Mongo::Error::Server
  getter error : Mongo::Error?
  getter write_errors : Hash(Int32, Mongo::ClientBulk::WriteError)
  getter write_concern_errors : Array(Mongo::ClientBulk::WriteConcernError)
  getter partial_result : Mongo::ClientBulk::WriteResult?

  def initialize(
    @error : Mongo::Error?,
    @write_errors : Hash(Int32, Mongo::ClientBulk::WriteError),
    @write_concern_errors : Array(Mongo::ClientBulk::WriteConcernError),
    @partial_result : Mongo::ClientBulk::WriteResult?,
  )
    if inner = @error
      inner.error_labels.each { |label| add_error_label(label) }
      @message = inner.message
    else
      @message = "client bulkWrite failed"
    end
  end

  def code : Int32?
    inner = @error
    inner.is_a?(Mongo::Error::Command) ? inner.code : nil
  end

  def code_name : String?
    inner = @error
    inner.is_a?(Mongo::Error::Command) ? inner.code_name : nil
  end

  def reply : BSON?
    inner = @error
    inner.is_a?(Mongo::Error::Command) ? inner.reply : nil
  end
end
