require "bson"
require "../commands"

# The *insert* command inserts one or more documents and returns a document containing the status of all inserts.
#
# NOTE: [for more details, please check the official MongoDB documentation](https://docs.mongodb.com/manual/reference/command/insert/).
module Mongo::Commands::Insert
  extend WriteCommand
  extend Retryable
  extend self

  # Generate `_id` on each document and put it first (CRUD prose: generated identifiers are the first field).
  # If `_id` is already present, leave the document as-is. BSON.new is a no-op for BSON.
  # When rebuilding, keep binary subtype (encrypted `0x06`). `[]=` of Bytes is generic `0x00`.
  def with_ids(documents : Array) : Array(BSON)
    documents.map { |elt|
      src = BSON.new(elt)
      if src.has_key?("_id")
        src
      else
        # Prepend `_id` as raw bytes. A second encode would allocate every
        # key and would turn binary subtype 0x06 into generic 0x00.
        prepend_id(src)
      end
    }
  end

  # Document size grows by the `_id` field: type + "_id" + NUL + 12 bytes.
  private def prepend_id(src : BSON) : BSON
    fields = src.size - 5
    total = src.size + 17
    bytes = Mongo::Messages::BufferPool.atomic_bytes(total)
    ptr = bytes.to_unsafe
    IO::ByteFormat::LittleEndian.encode(total.to_i32, bytes[0, 4])
    ptr[4] = 0x07_u8
    "_id".to_unsafe.copy_to(ptr + 5, 3)
    ptr[8] = 0_u8
    id = BSON::ObjectId.new
    id.to_slice.copy_to(bytes[9, 12])
    # Field bytes start after the 4-byte header. The old terminator is not copied.
    src.data[4, fields].copy_to(bytes[21, fields]) if fields > 0
    bytes[total - 1] = 0_u8
    BSON.view(bytes)
  end

  # Returns a pair of OP_MSG body and sequences associated with the command and arguments.
  def command(database : String, collection : Collection::CollectionKey, documents : Array, options)
    Commands.make({
      insert: collection,
      "$db":  database,
    }, sequences: {
      documents: with_ids(documents),
    }, options: options)
  end

  def retryable?(**args)
    # insertOne and insertMany are both retryable as a single insert command
    # (same txnNumber). Client-generated _id makes the retry safe.
    true unless prevent_retry(args)
  end

  # Transforms the server result.
  def result(bson : BSON)
    Common::InsertResult.from_bson bson
  end
end
