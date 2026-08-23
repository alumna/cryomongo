require "../tools"
require "../sessions"

# This module contains the [Database Commands](https://docs.mongodb.com/manual/reference/command/) supported by the `cryomongo` driver.
module Mongo::Commands
  # Base command class.
  module Command
    # Transforms the server result.
    def result(bson : BSON)
      Common::BaseResult.from_bson bson
    end

    macro extended
      def self.name
        \{{@type.name.split("::")[-1].camelcase(lower: true)}}
      end
    end
  end

  module WriteCommand
    macro extended
      extend Command
    end

    def write_command?(**args)
      true
    end
  end

  module ReadCommand
    macro extended
      extend Command
    end

    def read_command?(**args)
      true
    end
  end

  module MayUseSecondary
    def may_use_secondary?(**args)
      true
    end
  end

  module Retryable
    def prevent_retry(args)
      # Do not retry within a transaction.
      # In MongoDB 4.0 the only supported retryable write commands within a transaction are commitTransaction and abortTransaction.
      # Therefore drivers MUST NOT retry write commands within transactions even when retryWrites has been enabled on the MongoClient.
      # https://github.com/mongodb/specifications/blob/46918b8c9c21d88fb930f06fd8d496bc024cdd7f/source/transactions/transactions.rst#interaction-with-retryable-writes
      args["session"]?.try(&.is_transaction?)
    end

    def retryable?(**args)
      true unless prevent_retry(args)
    end
  end

  module AlwaysRetryable
    include Retryable

    def retryable?(**args)
      true
    end
  end

  # Common results.
  module Common
    # :nodoc:
    module Result
      macro included
        property ok : Float64
        @[BSON::Field(key: "operationTime")]
        property operation_time : BSON::Timestamp? = nil
        @[BSON::Field(key: "$clusterTime")]
        property cluster_time : Session::ClusterTime?
        @[BSON::Field(key: "recoveryToken")]
        property recovery_token : BSON?
      end
    end

    # :nodoc:
    macro result(name, root = true, &block)
      @[BSON::Options(camelize: "lower")]
      struct {{name.id}}
        include BSON::Serializable
        {% if root %}include ::Mongo::Commands::Common::Result{% end %}

        {{ yield }}
      end
    end

    # A Base MongoDB result.
    result(BaseResult)

    # WriteError bson sub-document.
    result(WriteError, root: false) {
      property index : Int32
      property code : Int32
      property errmsg : String

      def initialize(@index, @code, @errmsg); end
    }

    # WriteConcernError bson sub-document.
    result(WriteConcernError, root: false) {
      property code : Int32
      property errmsg : String
      @[BSON::Field(key: "errInfo")]
      property err_info : BSON?
      property error_labels : Array(String)?
    }

    # Cursor bson sub-document.
    result(Cursor, root: false) {
      property first_batch : Array(BSON)
      property id : Int64
      property ns : String
      property post_batch_resume_token : BSON?
    }

    # Upserted bson sub-document. Hand-written so `_id: null` can deserialize.
    struct Upserted
      getter index : Int32
      getter _id : BSON::Value?

      def initialize(@index, @_id); end

      def self.from_bson(bson : BSON) : self
        raw = bson["index"]?
        index = raw.as?(Int32) || raw.as?(Int64).try(&.to_i32) || 0
        new(index, bson["_id"]?)
      end
    end

    # In response to query commands.
    result(QueryResult) {
      property cursor : Cursor
    }

    # In response to insert commands.
    result(InsertResult) {
      property n : Int32?
      property write_errors : Array(WriteError)?
      property write_concern_error : WriteConcernError?
      # Client-side only. The server does not return inserted ids.
      @[BSON::Field(ignore: true)]
      property inserted_ids : Array(BSON::Value)? = nil
    }

    # In response to delete commands.
    result(DeleteResult) {
      property n : Int32?
      property write_errors : Array(WriteError)?
      property write_concern_error : WriteConcernError?
    }

    # In response to update commands.
    result(UpdateResult) {
      property n : Int32?
      property n_modified : Int32?
      property upserted : Array(Upserted)?
      property write_errors : Array(WriteError)?
      property write_concern_error : WriteConcernError?
    }

    # In response to findAndModify commands.
    result(FindAndModifyResult) {
      property value : BSON?
      property last_error_object : BSON?
    }
  end

  # Build a command body. *init* is one builder pass (`BSON.new`). All *options*
  # are written with one `append` so we do not rebuild the document per field.
  # :nodoc:
  def self.make(init, options = nil, sequences = nil, skip_nil = true)
    bson = BSON.new(init)
    if options
      bson.append do |builder|
        options.each { |key, value|
          skip_key = yield nil, key, value
          if skip_key == false && (skip_nil == false || !value.nil?)
            key_s = key.to_s
            if key_s == "read_preference"
              Tools.write_bson_field(builder, "$readPreference", value)
            elsif key_s == "max_time_ms" || key_s == "max_commit_time_ms"
              Tools.write_bson_field(builder, "maxTimeMS", value)
            else
              Tools.write_bson_field(builder, key_s.camelcase(lower: true), value)
            end
          end
        }
      end
    end
    {bson, sequences}
  end

  # :nodoc:
  def self.make(init, options = nil, sequences = nil, skip_nil = true)
    self.make(init, options, sequences, skip_nil) { false }
  end
end
