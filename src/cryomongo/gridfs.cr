require "./database"
require "./error"
require "./tools"
require "pipe"
require "wait_group"
require "./gridfs/*"

# GridFS is a specification for storing and retrieving files that exceed the BSON-document size limit of 16 MB.
module Mongo::GridFS
  # Holds an exception raised inside a stream fiber so close can re-raise it.
  private class StreamError
    property exception : Exception?
  end

  # Forwards reads and writes. close() waits for the background fiber.
  private class JoinStream < IO
    def initialize(@inner : IO, @wait : WaitGroup, @error : StreamError)
      @closed = false
    end

    def read(slice : Bytes) : Int32
      @inner.read(slice)
    end

    def write(slice : Bytes) : Nil
      @inner.write(slice)
    end

    def flush
      @inner.flush
    end

    def close
      return if @closed
      @closed = true
      @inner.close
      @wait.wait
      if exc = @error.exception
        raise exc
      end
    end

    def closed? : Bool
      @closed || @inner.closed?
    end
  end

  # A configured GridFS bucket instance.
  class Bucket
    @completed_indexes_check = false

    # Creates a new GridFSBucket object, managing a GridFS bucket within the given database.
    def initialize(
      @db : Database,
      *,
      # The bucket name. Defaults to 'fs'.
      @bucket_name : String = "fs",
      # The chunk size in bytes. Defaults to 255 KiB.
      @chunk_size_bytes : Int32 = 255 * 1024,
      @write_concern : WriteConcern? = nil,
      @read_concern : ReadConcern? = nil,
      @read_preference : ReadPreference? = nil,
    )
    end

    # One deadline for the whole GridFS call (stream lifetime or upload/download).
    private def start_deadline(timeout_ms : Int64?) : Mongo::Deadline?
      unless timeout_ms.nil?
        return Mongo::Deadline.from_timeout_ms(timeout_ms)
      end
      @db.inherited_deadline
    end

    private def write_concern
      @write_concern || @db.write_concern
    end

    private def read_concern
      @read_concern || @db.read_concern
    end

    private def read_preference
      @read_preference || @db.read_preference
    end

    # Opens an `IO` stream that the caller can write the contents of the file to.
    #
    # NOTE: The caller must flush and close the stream. `#close` waits until the
    # file document is written. Do not drop the stream without closing it.
    #
    # ```
    # gridfs = client["database"].grid_fs
    # io = gridfs.open_upload_stream(filename: "file.txt", chunk_size_bytes: 1024, metadata: {hello: "world"})
    # io << "some" << "text"
    # io.flush
    # io.close
    # ```
    def open_upload_stream(
      filename : String,
      *,
      id = nil,
      chunk_size_bytes : Int32? = nil,
      metadata = nil,
      session : Session::ClientSession? = nil,
      timeout_ms : Int64? = nil,
    ) : IO
      id ||= BSON::ObjectId.new
      chunk_size : Int32 = chunk_size_bytes || @chunk_size_bytes
      deadline = start_deadline(timeout_ms)

      check_indexes(bucket, chunks, session, deadline)

      reader, writer = Pipe.create(capacity: chunk_size)
      wait, error = start_stream_job {
        consume_upload(reader, id, filename, chunk_size, metadata, session, deadline)
      }
      JoinStream.new(writer, wait, error)
    end

    # Yields an `IO` stream that the caller can write the contents of the file to.
    #
    # NOTE: Will flush and close the stream after the block gets executed.
    #
    # ```
    # gridfs = client["database"].grid_fs
    # gridfs.open_upload_stream(filename: "file.txt", chunk_size_bytes: 1024, metadata: {hello: "world"}) { |io|
    #   io << "some text"
    # }
    # ```
    def open_upload_stream(
      filename : String,
      *,
      id : FileID = nil,
      chunk_size_bytes : Int32? = nil,
      metadata = nil,
      session : Session::ClientSession? = nil,
      timeout_ms : Int64? = nil,
      &block
    ) forall FileID
      id ||= BSON::ObjectId.new
      chunk_size : Int32 = chunk_size_bytes || @chunk_size_bytes
      deadline = start_deadline(timeout_ms)

      check_indexes(bucket, chunks, session, deadline)

      reader, writer = Pipe.create(capacity: chunk_size)
      wait, error = start_stream_job {
        consume_upload(reader, id, filename, chunk_size, metadata, session, deadline)
      }

      begin
        yield writer
        writer.flush
      ensure
        writer.close
        wait.wait
        if exc = error.exception
          raise exc
        end
      end
      id
    end

    private def consume_upload(reader, id, filename, chunk_size, metadata, session, deadline)
      length = upload_chunks_from(reader, id, chunk_size, session, deadline)
      insert_file_document(id, length, chunk_size, filename, metadata, session, deadline)
    ensure
      reader.close
    end

    # Uploads a user file to a GridFS bucket.
    #
    # The application supplies a custom file id or the driver will generate the file id.
    #
    # Reads the contents of the user file from the *source* Stream and uploads it
    # as chunks in the chunks collection. After all the chunks have been uploaded,
    # it creates a files collection document for *filename* in the files collection.
    #
    # Returns the id of the uploaded file.
    #
    # NOTE: It is the responsbility of the caller to flush and close the stream.
    #
    # ```
    # gridfs = client["database"].grid_fs
    # file = File.new("file.txt")
    # id = gridfs.upload_from_stream("file.txt", file)
    # file.close
    # puts id
    # ```
    def upload_from_stream(
      filename : String,
      stream : IO,
      *,
      id : FileID = nil,
      chunk_size_bytes : Int32? = nil,
      metadata = nil,
      session : Session::ClientSession? = nil,
      timeout_ms : Int64? = nil,
    ) forall FileID
      id ||= BSON::ObjectId.new
      chunk_size_bytes ||= @chunk_size_bytes
      deadline = start_deadline(timeout_ms)

      check_indexes(bucket, chunks, session, deadline)
      length = upload_chunks_from(stream, id, chunk_size_bytes, session, deadline)
      insert_file_document(id, length, chunk_size_bytes, filename, metadata, session, deadline)

      id
    end

    # Opens a Stream from which the application can read the contents of the stored file
    # specified by *id*.
    #
    # Returns a `IO` stream.
    #
    # ```
    # gridfs = client["database"].grid_fs
    # id = BSON::ObjectId.new("5eed35600000000000000000")
    # stream = gridfs.open_download_stream(id)
    # puts stream.gets_to_end
    # stream.close
    # ```
    def open_download_stream(id : FileID, *, session : Session::ClientSession? = nil, timeout_ms : Int64? = nil) : IO forall FileID
      deadline = start_deadline(timeout_ms)
      file = get_file(id, session, deadline)

      # to_i32 naturally raises on overflow. Using `!` was an unsafe bypass.
      reader, writer = Pipe.create(capacity: file.chunk_size.to_i32)

      wait, error = start_stream_job {
        begin
          each_chunk(file, session, deadline) { |chunk| writer.write(chunk.data) }
        ensure
          writer.close
        end
      }

      JoinStream.new(reader, wait, error)
    end

    # Downloads the contents of the stored file specified by *id* and writes
    # the contents to the *destination* Stream.
    #
    # ```
    # gridfs = client["database"].grid_fs
    # stream = IO::Memory.new
    # id = BSON::ObjectId.new("5eed35600000000000000000")
    # gridfs.download_to_stream(id, stream)
    # puts stream.rewind.gets_to_end
    # ```
    def download_to_stream(id : FileID, destination : IO, *, session : Session::ClientSession? = nil, timeout_ms : Int64? = nil) : Nil forall FileID
      deadline = start_deadline(timeout_ms)
      file = get_file(id, session, deadline)
      each_chunk(file, session, deadline) { |chunk| destination.write(chunk.data) }
    end

    # Opens a `IO` stream from which the application can read the contents of the stored file
    # specified by *filename* and an optional *revision*.
    #
    # Returns a `IO` stream.
    #
    # NOTE: It is the responsbility of the caller to close the stream.
    #
    # ```
    # gridfs = client["database"].grid_fs
    # stream = gridfs.open_download_stream_by_name("file", revision: 2)
    # puts stream.gets_to_end
    # stream.close
    # ```
    #
    # #### About the the *revision* argument:
    #
    # Specifies which revision (documents with the same filename and different uploadDate)
    # of the file to retrieve. Defaults to -1 (the most recent revision).
    #
    # Revision numbers are defined as follows:
    # - 0 = the original stored file
    # - 1 = the first revision
    # - 2 = the second revision
    #
    # etc…
    #
    # - -2 = the second most recent revision
    # - -1 = the most recent revision
    def open_download_stream_by_name(filename : String, revision : Int32 = -1, *, session : Session::ClientSession? = nil, timeout_ms : Int64? = nil) : IO
      deadline = start_deadline(timeout_ms)
      file = get_file_by_name(filename, revision, session, deadline)

      # to_i32 naturally raises on overflow. Using `!` was an unsafe bypass.
      reader, writer = Pipe.create(capacity: file.chunk_size.to_i32)

      wait, error = start_stream_job {
        begin
          each_chunk(file, session, deadline) { |chunk| writer.write(chunk.data) }
        ensure
          writer.close
        end
      }

      JoinStream.new(reader, wait, error)
    end

    # Downloads the contents of the stored file specified by *filename* and by an optional *revision* and writes the contents to the *destination* `IO` stream.
    #
    # See: `open_download_stream_by_name` for how the revision is calculated.
    #
    # ```
    # gridfs = client["database"].grid_fs
    # io = IO::Memory.new
    # gridfs.download_to_stream_by_name("file", io, revision: -1)
    # puts io.to_s
    # ```
    def download_to_stream_by_name(filename : String, destination : IO, revision : Int32 = -1, *, session : Session::ClientSession? = nil, timeout_ms : Int64? = nil) : Nil
      deadline = start_deadline(timeout_ms)
      file = get_file_by_name(filename, revision, session, deadline)
      each_chunk(file, session, deadline) { |chunk| destination.write(chunk.data) }
    end

    # Given an *id*, delete this stored file’s files collection document and associated chunks from a GridFS bucket.
    #
    # ```
    # gridfs = client["database"].grid_fs
    # id = BSON::ObjectId.new("5eed35600000000000000000")
    # gridfs.delete(id)
    # ```
    def delete(id : FileID, *, session : Session::ClientSession? = nil, timeout_ms : Int64? = nil) : Nil forall FileID
      deadline = start_deadline(timeout_ms)
      delete_result = bucket.delete_one({_id: id}, write_concern: write_concern, session: session, deadline: deadline)
      chunks.delete_many({files_id: id}, write_concern: write_concern, session: session, deadline: deadline)
      raise Mongo::Error.new "File not found." if delete_result.try &.n == 0
    end

    # Find and return the files collection documents that match *filter*.
    #
    # ```
    # gridfs = client["database"].grid_fs
    # gridfs.find({
    #   length: {"$gte": 5000},
    # })
    # ```
    def find(
      filter = BSON.new,
      *,
      allow_disk_use : Bool? = nil,
      batch_size : Int32? = nil,
      limit : Int32? = nil,
      max_time_ms : Int64? = nil,
      no_cursor_timeout : Bool? = nil,
      skip : Int32? = nil,
      sort = nil,
      session : Session::ClientSession? = nil,
      timeout_ms : Int64? = nil,
    ) : Cursor::Wrapper(File(BSON::Value))
      deadline = start_deadline(timeout_ms)
      cursor = bucket.find(
        filter,
        allow_disk_use: allow_disk_use,
        batch_size: batch_size,
        limit: limit,
        max_time_ms: max_time_ms,
        no_cursor_timeout: no_cursor_timeout,
        skip: skip,
        sort: sort,
        read_concern: read_concern,
        read_preference: read_preference,
        session: session,
        timeout_mode: Mongo::TimeoutMode::CursorLifetime,
        deadline: deadline
      )
      Cursor::Wrapper(File(BSON::Value)).new(cursor)
    end

    # Renames the stored file with the specified *id*.
    #
    # ```
    # gridfs = client["database"].grid_fs
    # id = BSON::ObjectId.new("5eed35600000000000000000")
    # gridfs.rename(id, new_filename: "new_name.txt")
    # ```
    def rename(id : FileID, new_filename : String, *, session : Session::ClientSession? = nil, timeout_ms : Int64? = nil) : Nil forall FileID
      deadline = start_deadline(timeout_ms)
      result = bucket.update_one({_id: id}, {"$set": {filename: new_filename}}, session: session, deadline: deadline)
      raise Mongo::Error.new "File not found." if result.try(&.n) == 0
    end

    # Drops the files and chunks collections associated with this bucket.
    #
    # ```
    # gridfs = client["database"].grid_fs
    # gridfs.drop
    # ```
    def drop(*, session : Session::ClientSession? = nil, timeout_ms : Int64? = nil)
      deadline = start_deadline(timeout_ms)
      bucket.delete_many(BSON.new, session: session, deadline: deadline)
      chunks.delete_many(BSON.new, session: session, deadline: deadline)
    end

    private module Internal
      def bucket
        @db["#{@bucket_name}.files"]
      end

      def chunks
        @db["#{@bucket_name}.chunks"]
      end

      def check_indexes(bucket, chunks, session = nil, deadline = nil)
        # see: https://github.com/mongodb/specifications/blob/master/source/gridfs/gridfs-spec.rst#before-write-operations
        return if @completed_indexes_check
        if bucket.find_one(projection: {_id: 1}, session: session, deadline: deadline).nil?
          check_collection_index(bucket, {filename: 1, uploadDate: 1}, session, deadline)
          check_collection_index(chunks, {files_id: 1, n: 1}, session, deadline)
        end
        @completed_indexes_check = true
      end

      def check_collection_index(collection, keys, session = nil, deadline = nil)
        cursor = nil
        begin
          cursor = collection.list_indexes(session: session, deadline: deadline)
          found = false
          cursor.each do |idx|
            if index_keys_match?(idx, keys)
              found = true
              break
            end
          end
          return if found
        rescue e : Mongo::Error::Command
          # 26: collection does not exist yet. Create the index next.
          raise e unless e.code == 26
        ensure
          cursor.try(&.close)
        end

        begin
          collection.create_index(
            keys: keys,
            session: session,
            deadline: deadline
          )
        rescue e : Mongo::Error::Command
          # 85/86: the index is already there.
          raise e unless e.code.in?({85, 86})
        end
      end

      private def index_keys_match?(index : BSON, keys) : Bool
        key_doc = index["key"]?.as?(BSON)
        return false unless key_doc
        expected = BSON.new(keys)
        return false unless key_doc.size == expected.size
        expected.each do |ek, ev|
          av = key_doc[ek]?
          return false unless av
          return false unless index_key_num(av) == index_key_num(ev)
        end
        true
      end

      private def index_key_num(v) : Float64
        case v
        when Int32
          v.to_f64
        when Int64
          v.to_f64
        when Float64
          v
        else
          0.0
        end
      end

      # Do not store metadata: null. BSON::Serializable cannot read a BSON null
      # into a BSON? field, and the spec says metadata is optional.
      private def insert_file_document(id, length, chunk_size, filename, metadata, session, deadline = nil)
        doc = BSON.build do |builder|
          Tools.write_bson_field(builder, "_id", id)
          builder["length"] = length
          builder["chunkSize"] = chunk_size
          builder["uploadDate"] = Time.utc
          builder["filename"] = filename
          builder["metadata"] = metadata unless metadata.nil?
        end
        bucket.insert_one(doc, write_concern: write_concern, session: session, deadline: deadline)
      end

      def fill_slice(io : IO, slice : Bytes)
        io.read_greedy(slice)
      end

      CHUNK_BATCH = 8

      # One insertMany per batch. Copy each chunk out of the read buffer first.
      def upload_chunks_from(io, id, chunk_size, session, deadline)
        index = 0
        length = 0_i64
        buffer = Bytes.new(chunk_size)
        docs = [] of BSON
        loop do
          read_bytes = fill_slice(io, buffer.to_slice)
          break if read_bytes == 0
          docs << BSON.new({
            files_id: id,
            n:        index,
            data:     buffer[0, read_bytes].dup,
          })
          if docs.size >= CHUNK_BATCH
            flush_chunk_docs(docs, session, deadline)
          end
          length += read_bytes
          index += 1
          break if read_bytes < chunk_size
        rescue IO::EOFError
          break
        end
        flush_chunk_docs(docs, session, deadline)
        length
      end

      def flush_chunk_docs(docs, session, deadline)
        return if docs.empty?
        chunks.insert_many(docs, write_concern: write_concern, session: session, deadline: deadline)
        docs.clear
      end

      # One find cursor for all chunks, in order. A zero-length file must not
      # query chunks (GridFS spec). An extra empty chunk is ignored.
      def each_chunk(file, session, deadline, &)
        return if file.length == 0

        remaining = file.length
        expected = 0
        cursor = chunks.find(
          {files_id: file._id},
          sort: {n: 1},
          read_preference: read_preference,
          read_concern: read_concern,
          session: session,
          deadline: deadline,
        )
        cursor.each do |doc|
          chunk = Chunk(typeof(file._id)).from_bson(doc)
          raise Mongo::Error.new("Chunk not found") unless chunk.n == expected
          integrity_check!(file, chunk, remaining)
          yield chunk
          remaining -= chunk.data.size
          expected += 1
        end
        raise Mongo::Error.new("Chunk not found") unless expected == chunk_count(file)
      end

      # Run stream I/O in a fiber. The caller joins through JoinStream#close.
      # The block is captured so it can run inside spawn (no yield there).
      private def start_stream_job(&work : ->) : {WaitGroup, StreamError}
        wait = WaitGroup.new
        error = StreamError.new
        wait.add(1)
        spawn do
          begin
            work.call
          rescue e
            error.exception = e
          ensure
            wait.done
          end
        end
        {wait, error}
      end

      def get_file(id : FileID, session = nil, deadline = nil) : File(FileID) forall FileID
        file = bucket.find_one({_id: id}, read_preference: read_preference, read_concern: read_concern, session: session, deadline: deadline)
        raise Mongo::Error.new "Cannot find file with id: #{id}" unless file
        File(FileID).from_bson(file)
      end

      def get_file_by_name(name : String, revision : Int32 = -1, session = nil, deadline = nil) : File(BSON::Value)
        sort_order = revision >= 0 ? 1 : -1
        file = bucket.find_one(
          {filename: name},
          sort: {uploadDate: sort_order},
          skip: revision >= 0 ? revision : -revision - 1,
          read_preference: read_preference,
          read_concern: read_concern,
          session: session,
          deadline: deadline
        )
        raise Mongo::Error.new "Cannot find revision #{revision} of the file named: #{name}" unless file
        File(BSON::Value).from_bson(file)
      end

      def chunk_count(file : File(FileID)) : Int64 forall FileID
        return 0_i64 if file.length == 0
        count = file.length // file.chunk_size
        count += 1 if file.length % file.chunk_size != 0
        count
      end

      def get_chunk(id : FileID, n : Int64, session = nil, deadline = nil) forall FileID
        chunk = chunks.find_one({files_id: id, n: n}, sort: {n: 1}, read_preference: read_preference, read_concern: read_concern, session: session, deadline: deadline)
        raise Mongo::Error.new "Chunk not found" unless chunk
        Chunk(FileID).from_bson(chunk)
      end

      def integrity_check!(file : File, chunk : Chunk, remaining : Int64)
        if chunk.data.size != remaining && chunk.data.size < file.chunk_size
          raise Mongo::Error.new "Wrong chunk size"
        end
      end
    end

    include Internal
  end
end
