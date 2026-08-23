require "./collection"
require "./tools"
require "./commands/**"
require "./bulk/*"

# A bulk operations builder.
#
# ```
# # A Bulk instance can be obtained by calling `.bulk()` on a collection.
# bulk = collection.bulk(ordered: true)
# # Then, operations can be added…
# 500.times { |idx|
#   bulk.insert_one({number: idx})
#   bulk.delete_many({number: {"$lt": 450}})
# }
# # …and they will be performed once the bulk gets executed.
# bulk_result = bulk.execute(write_concern: Mongo::WriteConcern.new(w: 1))
# pp bulk_result
# ```
class Mongo::Bulk
  # The target collection.
  getter collection : Mongo::Collection
  # Whether the bulk is ordered.
  getter? ordered : Bool

  @models = [] of WriteModel
  @max_bson_object_size : Int32 = 16 * 1024 * 1024
  @max_write_batch_size : Int32 = 100_000
  @executed = Atomic(UInt8).new(0)
  @session : Session::ClientSession

  # :nodoc:
  def initialize(@collection, @ordered = true, *, session = nil)
    @session = session || Session::ClientSession.new(@collection.database.client)
    # handshake_result = @collection.database.client.handshake_reply
    # @max_bson_object_size = handshake_result.max_bson_object_size
    # @max_write_batch_size = handshake_result.max_write_batch_size
  end

  # :nodoc:
  def initialize(collection, ordered, @models, *, session = nil)
    initialize(collection, ordered, session: session)
  end

  # Insert a single document.
  def insert_one(document)
    @models << InsertOne.new(BSON.new document)
    self
  end

  # Delete a single document.
  def delete_one(filter, **options)
    @models << DeleteOne.new(BSON.new(filter), **options)
    self
  end

  # Delete one or more documents.
  def delete_many(filter, **options)
    @models << DeleteMany.new(BSON.new(filter), **options)
    self
  end

  # Replace one document.
  def replace_one(filter, replacement, **options)
    @models << ReplaceOne.new(BSON.new(filter), BSON.new(replacement), **options)
    self
  end

  # Update one document.
  def update_one(filter, update, **options)
    @models << UpdateOne.new(BSON.new(filter), BSON.new(update), **options)
    self
  end

  # Update many documents.
  def update_many(filter, update, **options)
    @models << UpdateMany.new(BSON.new(filter), BSON.new(update), **options)
    self
  end

  # Execute the bulk operations stored in this `Bulk` instance.
  def execute(write_concern : WriteConcern? = nil, bypass_document_validation : Bool? = nil, comment = nil, let = nil, timeout_ms : Int64? = nil)
    _, not_executed = @executed.compare_and_set(0_u8, 1_u8)
    raise Mongo::Bulk::Error.new "Cannot execute a bulk operation more than once" unless not_executed

    options = {
      write_concern:              write_concern,
      bypass_document_validation: bypass_document_validation,
      comment:                    comment,
    }

    bulk_deadline = Mongo::Deadline.from_timeout_ms(timeout_ms)
    indexed_models = @models.map_with_index { |model, index| {index, model} }
    unless @ordered
      # Reorder by wire-command family for fewer round-trips, but keep original indices.
      indexed_models.sort_by! { |_, model| command_family(model) }
    end
    # Group consecutive models that share a wire command (insert / update / delete).
    group_family = nil
    group = [] of BSON
    group_indices = [] of Int32
    group_bytesize = 0
    operation_id = 0_i64
    results = WriteResult.new

    indexed_models.each { |original_index, model|
      family = command_family(model)
      if family != group_family
        process_group(group_family, group, group_indices, results, options, operation_id, bulk_deadline, let)
        return results if early_return?(results)
        group_family = family
        group_bytesize = 0
      end

      bson = format_bson(model)

      if group_bytesize + bson.size >= @max_bson_object_size || group.size >= @max_write_batch_size
        process_group(group_family, group, group_indices, results, options, operation_id, bulk_deadline, let)
        return results if early_return?(results)
        group_bytesize = 0
      end

      group << bson
      group_indices << original_index
      group_bytesize += bson.size
      operation_id += 1_i64
    }

    process_group(group_family, group, group_indices, results, options, operation_id, bulk_deadline, let)

    results
  ensure
    # One implicit session for the whole bulk. Return it only when execute ends.
    if @session.implicit?
      @session.end
    end
  end

  # Same wire command can carry mixed models (updateOne + replaceOne, deleteOne + deleteMany).
  private def command_family(model : WriteModel) : Symbol
    case model
    when InsertOne
      :insert
    when DeleteOne, DeleteMany
      :delete
    when ReplaceOne, UpdateOne, UpdateMany
      :update
    else
      raise Mongo::Bulk::Error.new "Invalid Operation"
    end
  end

  private def format_bson(model : WriteModel) : BSON
    case model
    when InsertOne
      model.document
    when DeleteOne
      Tools.merge_bson({
        q:     model.filter,
        limit: 1,
      }, {
        hint:      model.hint,
        collation: model.collation,
      }) { |_, value|
        value.nil?
      }
    when DeleteMany
      Tools.merge_bson({
        q:     model.filter,
        limit: 0,
      }, {
        hint:      model.hint,
        collation: model.collation,
      }) { |_, value|
        value.nil?
      }
    when ReplaceOne
      Tools.merge_bson({
        q:     model.filter,
        u:     Collection.validate_replacement!(model.replacement),
        multi: false,
      }, {
        hint:      model.hint,
        collation: model.collation,
        upsert:    model.upsert,
        sort:      model.sort,
      }) { |_, value|
        value.nil?
      }
    when UpdateOne
      Tools.merge_bson({
        q:     model.filter,
        u:     Collection.validate_update!(model.update),
        multi: false,
      }, {
        hint:          model.hint,
        collation:     model.collation,
        upsert:        model.upsert,
        array_filters: model.array_filters,
        sort:          model.sort,
      }) { |_, value|
        value.nil?
      }
    when UpdateMany
      Tools.merge_bson({
        q:     model.filter,
        u:     Collection.validate_update!(model.update),
        multi: true,
      }, {
        hint:          model.hint,
        collation:     model.collation,
        upsert:        model.upsert,
        array_filters: model.array_filters,
      }) { |_, value|
        value.nil?
      }
    else
      raise Mongo::Bulk::Error.new "Invalid Operation"
    end.as(BSON)
  end

  private def process_group(family, group : Array(BSON), group_indices : Array(Int32), results, options, operation_id, deadline : Mongo::Deadline?, let)
    return if group.size < 1

    options = options.merge({
      ordered: @ordered,
    })

    result = nil
    case family
    when :insert
      result = @collection.command(Commands::Insert, documents: group, options: options, session: @session, operation_id: operation_id, deadline: deadline)
    when :delete
      # CRUD spec: bulkWrite let is sent on update and delete, not on insert.
      result = @collection.command(Commands::Delete, deletes: group, options: options.merge({let: let.try { BSON.new(let) }}), session: @session, operation_id: operation_id, deadline: deadline)
    when :update
      result = @collection.command(Commands::Update, updates: group, options: options.merge({let: let.try { BSON.new(let) }}), session: @session, operation_id: operation_id, deadline: deadline)
    else
      raise Mongo::Bulk::Error.new "Invalid Operation"
    end

    if result
      merge_results(results, result, group_indices)
    end

    group.clear
    group_indices.clear
  end

  private def merge_results(results, result, group_indices : Array(Int32))
    case result
    when Commands::Common::InsertResult
      result.n.try { |n| results.n_inserted += n }
    when Commands::Common::DeleteResult
      result.n.try { |n| results.n_removed += n }
    when Commands::Common::UpdateResult
      upserted_size = result.upserted.try(&.size) || 0
      results.n_upserted += upserted_size
      result.n.try { |n|
        results.n_matched += (n - upserted_size)
      }
      result.n_modified.try { |n| results.n_modified += n }
      if upserted = result.upserted
        upserted.each { |upsert|
          original = group_indices[upsert.index]? || upsert.index
          results.upserted << Commands::Common::Upserted.new(
            original,
            upsert._id
          )
        }
      end
    end

    if write_errors = result.write_errors
      write_errors.each { |write_error|
        original = group_indices[write_error.index]? || write_error.index
        results.write_errors << Commands::Common::WriteError.new(
          original,
          write_error.code,
          write_error.errmsg
        )
      }
    end

    if write_concern_error = result.write_concern_error
      results.write_concern_errors << write_concern_error
    end
  end

  private def early_return?(results)
    @ordered && results.write_errors.size > 0
  end
end

# Is raised while trying to build or execute a bulk operation.
class Mongo::Bulk::Error < Mongo::Error
end
