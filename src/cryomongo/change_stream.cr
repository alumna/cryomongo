# Change streams allow applications to access real-time data changes without the complexity and risk of tailing the oplog.
#
# Applications can use change streams to subscribe to all data changes on a single collection, a database, or an entire deployment,
# and immediately react to them. Because change streams use the aggregation framework, applications can also filter for specific changes
# or transform the notifications at will.
#
# NOTE: [for more details, please check the official manual](https://docs.mongodb.com/manual/changeStreams/index.html).
module Mongo::ChangeStream
  @[BSON::Options(camelize: "lower")]
  struct Document(T)
    include BSON::Serializable

    # The id functions as an opaque token for use when resuming an interrupted
    # change stream.
    getter _id : BSON

    # Describes the type of operation represented in this change notification.
    # "insert" | "update" | "replace" | "delete" | "invalidate" | "drop" | "dropDatabase" | "rename"
    getter operation_type : String

    # Contains two fields: “db” and “coll” containing the database and
    # collection name in which the change happened.
    getter ns : BSON

    # Only present for ops of type ‘insert’, ‘update’, ‘replace’, and
    # ‘delete’.
    #
    # For unsharded collections this contains a single field, _id, with the
    # value of the _id of the document updated.  For sharded collections,
    # this will contain all the components of the shard key in order,
    # followed by the _id if the _id isn’t part of the shard key.
    getter document_key : BSON? = nil

    # Only present for ops of type ‘update’.
    #
    # Contains a description of updated and removed fields in this
    # operation.
    getter update_description : UpdateDescription? = nil

    # Always present for operations of type ‘insert’ and ‘replace’. Also
    # present for operations of type ‘update’ if the user has specified ‘updateLookup’
    # in the ‘fullDocument’ arguments to the ‘$changeStream’ stage.
    #
    # For operations of type ‘insert’ and ‘replace’, this key will contain the
    # document being inserted, or the new version of the document that is replacing
    # the existing document, respectively.
    #
    # For operations of type ‘update’, this key will contain a copy of the full
    # version of the document from some point after the update occurred. If the
    # document was deleted since the updated happened, it will be null.
    getter full_document : T? = nil

    @[BSON::Options(camelize: "lower")]
    struct UpdateDescription
      include BSON::Serializable

      # A document containing key:value pairs of names of the fields that were
      # changed, and the new value for those fields.
      getter updated_fields : BSON

      # An array of field names that were removed from the document.
      getter removed_fields : Array(String)
    end
  end

  class Cursor < ::Mongo::Cursor
    # The resume_token can be used to create a change stream that will start from this cursor position.
    getter resume_token : BSON? = nil

    @options : NamedTuple(
      pipeline: Array(BSON),
      full_document: String?,
      start_at_operation_time: Time?,
      resume_after: BSON?,
      start_after: BSON?,
      max_time_ms: Int64?,
      batch_size: Int32?,
      collation: Collation?,
      read_concern: ReadConcern?,
      read_preference: ReadPreference?,
      collection: Collection::CollectionKey,
      database: String)
    # postBatchResumeToken from the current aggregate/getMore batch.
    @batch_pbrt : BSON? = nil
    # operationTime saved from an empty first aggregate with no user resume token.
    @saved_operation_time : BSON::Timestamp? = nil
    # True after at least one change document has been returned.
    @seen_document : Bool = false
    # Timestamp used only while resuming (original aggregate operationTime).
    @resume_start_at : BSON::Timestamp? = nil

    # :nodoc:
    def initialize(@client : Mongo::Client, @session : Session::ClientSession? = nil, @limit : Int32? = nil, **@options)
      @await_time_ms = options["max_time_ms"]?
      @tailable = true
      @yielded = 0
      @session = @session || Session::ClientSession.new(@client)
      @resume_token = options["start_after"]? || options["resume_after"]?

      @cursor_id = 0
      @batch_size = options["batch_size"]?
      @batch = [] of BSON
      @database = options["database"]
      @collection = options["collection"]

      result = init(**@options)
      apply_init_result(result)
    end

    # Will convert the elements to the `Mongo::ChangeStream::Document(T)` type while iterating the `Cursor`.
    #
    # NOTE: see `Mongo::Cursor.of`
    def of(type : T) forall T
      {% begin %}
      Cursor::Wrapper(Mongo::ChangeStream::Document({{T.instance}})).new(self)
      {% end %}
    end

    def next : BSON | Iterator::Stop
      loop do
        begin
          element = super
          apply_document_token(element) if element.is_a?(BSON)
          return element
        rescue e : Mongo::Error
          raise e unless resumable?(e)
          resume_after_error
        end
      end
    end

    # One getMore at most. Does not block waiting for a later change after an
    # empty batch. Use this to read the latest resume token while idle.
    def try_next : BSON?
      loop do
        begin
          element = super
          apply_document_token(element) if element
          return element
        rescue e : Mongo::Error
          raise e unless resumable?(e)
          resume_after_error
        end
      end
    end

    protected def fetch_more
      reply = super
      if reply
        if token = reply.cursor.post_batch_resume_token
          @batch_pbrt = token
          # Empty batch: cache PBRT so idle streams can still resume.
          @resume_token = token if @batch.empty?
        end
      end
      reply
    end

    private def apply_init_result(result : Commands::Common::QueryResult?)
      raise Mongo::Error.new("Change stream initialization failed") unless result

      @cursor_id = result.cursor.id
      @batch = result.cursor.first_batch
      @batch_index = 0
      @database, @collection = result.cursor.ns.split(".", 2)
      @server_description = @session.try(&.last_operation_server)
      @batch_pbrt = result.cursor.post_batch_resume_token

      if token = @batch_pbrt
        @resume_token = token if @batch.empty?
      elsif @batch.empty? &&
            @options["start_at_operation_time"]?.nil? &&
            @options["resume_after"]?.nil? &&
            @options["start_after"]?.nil?
        @saved_operation_time = result.operation_time
      end
    end

    private def apply_document_token(element : BSON)
      # After the last document in the batch, prefer the postBatchResumeToken.
      if batch_consumed? && (pbrt = @batch_pbrt)
        @resume_token = pbrt
      elsif token = element["_id"]?.try &.as?(BSON)
        @resume_token = token
      else
        close
        raise Mongo::Error.new("Cannot provide resume functionality when the resume token is missing")
      end
      @seen_document = true
    end

    # see: https://github.com/mongodb/specifications/blob/master/source/change-streams/change-streams.md#resumable-error
    private def resumable?(error : Mongo::Error) : Bool
      # Aggregate errors are not resumable. Only getMore (and client/network) errors are.
      case error
      when Error::Command
        return true if error.code == 43 # CursorNotFound is always resumable
        wire_version = @server_description.try(&.max_wire_version) || 0
        if wire_version >= 9
          error.has_error_label?("ResumableChangeStreamError")
        else
          error.resumable?
        end
      else
        # Any non-server error (network, client, server selection) is resumable.
        !error.is_a?(Error::Server)
      end
    end

    private def resume_after_error
      # Kill only on the pinned server. Never end the session. Spec: same lsid.
      kill_quietly
      @server_description = nil
      @resume_start_at = nil

      result = if token = @resume_token
                 use_start_after = !@options["start_after"]?.nil? && !@seen_document
                 init(**@options.merge({
                   resume_after:            use_start_after ? nil : token,
                   start_after:             use_start_after ? token : nil,
                   start_at_operation_time: nil,
                 }))
               elsif saved = @saved_operation_time
                 @resume_start_at = saved
                 init(**@options.merge({
                   resume_after:            nil,
                   start_after:             nil,
                   start_at_operation_time: nil,
                 }))
               else
                 init(**@options)
               end

      @resume_start_at = nil
      apply_init_result(result)
    end

    private def init(
      pipeline : Array(BSON) = [] of BSON,
      full_document : String? = nil,
      start_at_operation_time : Time? = nil,
      resume_after : BSON? = nil,
      start_after : BSON? = nil,
      max_time_ms : Int64? = nil,
      batch_size : Int32? = nil,
      collation : Collation? = nil,
      read_concern : ReadConcern? = nil,
      read_preference : ReadPreference? = nil,
      collection : Collection::CollectionKey = nil,
      database : String = nil,
    )
      start_at = @resume_start_at || start_at_operation_time.try { |time|
        BSON::Timestamp.new(time.to_unix.to_u32, 1_u32)
      }

      full_pipeline = self.make_pipeline(
        pipeline: pipeline,
        full_document: full_document,
        resume_after: resume_after,
        start_after: start_after,
        start_at_operation_time: start_at
      )

      # Aggregate honors cursor.batchSize, not top-level batchSize.
      # maxAwaitTimeMS belongs on getMore only (@await_time_ms).
      @client.command(
        Commands::Aggregate,
        pipeline: full_pipeline,
        collection: collection,
        database: database,
        read_concern: read_concern,
        read_preference: read_preference,
        session: @session,
        options: {
          cursor:    batch_size.try { {batchSize: batch_size} },
          collation: collation,
        }
      )
    end

    private def make_pipeline(*, pipeline, full_document, resume_after, start_after, start_at_operation_time)
      change_stream_stage = Tools.merge_bson(NamedTuple.new, {
        full_document:           full_document,
        resume_after:            resume_after,
        start_at_operation_time: start_at_operation_time,
        start_after:             start_after,
        allChangesForCluster:    (@options["database"]? == "admin") || nil,
      })
      [
        BSON.new({
          "$changeStream": change_stream_stage,
        }),
      ].concat(pipeline)
    end
  end
end
