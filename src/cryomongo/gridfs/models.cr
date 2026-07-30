module Mongo::GridFS
  # A GridFS file document.
  @[BSON::Options(camelize: "lower")]
  struct File(FileID)
    include BSON::Serializable

    # A unique ID for this document. Usually this will be of type ObjectId, but a custom _id value provided by the application may be of any type.
    property _id : FileID
    # The name of this stored file; this does not need to be unique.
    property filename : String = ""
    # The length of this stored file, in bytes.
    property length : Int64
    # The size, in bytes, of each data chunk of this file. This value is configurable by file. The default is 255 KiB.
    property chunk_size : Int64
    # The date and time this file was added to GridFS, stored as a BSON datetime value.
    property upload_date : Time
    # Any additional application data the user wishes to store.
    property metadata : BSON?
  end

  # A GridFS chunk document.
  private struct Chunk(FileID)
    include BSON::Serializable

    # A unique ID for this document of type BSON ObjectId.
    property _id : BSON::ObjectId
    # The id for this file (the _id from the files collection document). This field takes the type of the corresponding _id in the files collection.
    property files_id : FileID
    # The index number of this chunk, zero-based.
    property n : Int32
    # A chunk of data from the user file.
    property data : Bytes
  end
end
