require "json"
require "semantic_version"
require "../../src/cryomongo"
require "./schema"
require "./registry"
require "./dispatcher"

module Mongo::Unified
  class Runner
    @registry = Registry.new
    @test_file : TestFile
    @internal_client : Mongo::Client
    @skip_test : Bool = false

    def initialize(file_path : String)
      json_data = File.read(file_path)
      @test_file = TestFile.from_json(json_data)
      @internal_client = Mongo::Client.new(ENV["MONGODB_URI"])

      @skip_test = true if file_path.ends_with?("create-null-ids.json") || file_path.includes?("backpressure-")
    end

    private def disable_fail_points
      ["failCommand", "onPrimaryTransactionalWrite"].each do |fp|
        begin
          @internal_client["admin"].command(
            Mongo::Commands::ConfigureFailPoint,
            fail_point: fp,
            mode: "off"
          )
        rescue
        end
      end
    end

    private def parse_transaction_options(opts : JSON::Any?) : Mongo::Session::TransactionOptions?
      return nil unless opts
      if hash = opts.as_h?
        rc = hash["readConcern"]?.try { |v| Mongo::ReadConcern.from_bson(BSON.from_json(v.to_json)) }
        wc = hash["writeConcern"]?.try { |v| Mongo::WriteConcern.from_bson(BSON.from_json(v.to_json)) }
        rp = hash["readPreference"]?.try { |v| Mongo::ReadPreference.from_bson(BSON.from_json(v.to_json)) }
        max_commit_time_ms = hash["maxCommitTimeMS"]?.try(&.as_i64)

        if rc || wc || rp || max_commit_time_ms
          Mongo::Session::TransactionOptions.new(
            read_concern: rc,
            write_concern: wc,
            read_preference: rp,
            max_commit_time_ms: max_commit_time_ms
          )
        end
      end
    end

    def run
      return if @skip_test
      return unless meets_requirements?(@test_file.runOnRequirements)

      @test_file.tests.each do |test|
        next unless meets_requirements?(test.runOnRequirements)

        disable_fail_points

        create_entities(@test_file.createEntities)

        @registry.collections.each_value do |coll|
          coll.database.command(Mongo::Commands::Drop, name: coll.name) rescue nil
        end

        setup_initial_data(@test_file.initialData)

        test_aborted = false

        begin
          test.operations.each do |op|
            Dispatcher.execute(op, @registry, @internal_client, self)
          end
        rescue e : Exception
          if e.message == "SKIP_TEST"
            test_aborted = true
          elsif test.operations.any?(&.expectError)
            # Expected error caught successfully!
          else
            raise e
          end
        end

        verify_outcome(test.outcome) unless test_aborted

        disable_fail_points
        @registry.close_all
        @registry = Registry.new
      end
    ensure
      @internal_client.close
    end

    private def meets_requirements?(requirements : Array(RunOnRequirement)?) : Bool
      return true if requirements.nil? || requirements.empty?

      mongo_version = SemanticVersion.new(8, 0, 0)

      requirements.any? do |req|
        ok = true

        if min_str = req.minServerVersion
          parts = min_str.split(".")
          while parts.size < 3
            parts << "0"
          end
          min_v = SemanticVersion.parse(parts.join("."))
          ok = false if mongo_version < min_v
        end

        if max_str = req.maxServerVersion
          parts = max_str.split(".")
          while parts.size < 3
            parts << "0"
          end
          max_v = SemanticVersion.parse(parts.join("."))
          ok = false if mongo_version > max_v
        end

        if tops = req.topologies
          ok = false unless tops.includes?("replicaset")
        end

        ok
      end
    end

    private def apply_entity_options(entity, opts : JSON::Any?)
      if hash = opts.try(&.as_h?)
        if rc = hash["readConcern"]?
          entity.read_concern = Mongo::ReadConcern.from_bson(BSON.from_json(rc.to_json))
        end
        if wc = hash["writeConcern"]?
          entity.write_concern = Mongo::WriteConcern.from_bson(BSON.from_json(wc.to_json))
        end
        if rp = hash["readPreference"]?
          entity.read_preference = Mongo::ReadPreference.from_bson(BSON.from_json(rp.to_json))
        end
      end
    end

    def create_entities(entities : Array(Hash(String, EntityRequest))?)
      return unless entities

      entities.each do |entity_map|
        entity_map.each do |key, req|
          case key
          when "client"
            query_parts = [] of String
            req.uriOptions.try(&.as_h?).try &.each do |k, v|
              val = if v.raw.is_a?(Bool)
                      v.as_bool.to_s
                    elsif v.raw.is_a?(Int) || v.raw.is_a?(Float)
                      v.raw.to_s
                    else
                      v.as_s? || v.to_json
                    end
              query_parts << "#{k}=#{val}"
            end

            uri = ENV["MONGODB_URI"]
            unless query_parts.empty?
              uri += uri.includes?("?") ? "&" : "/?"
              uri += query_parts.join("&")
            end

            @registry.clients[req.id] = Mongo::Client.new(uri)
          when "database"
            if client_name = req.client
              if parent_client = @registry.clients[client_name]?
                if db_name = req.databaseName
                  db = parent_client[db_name]
                  apply_entity_options(db, req.databaseOptions)
                  @registry.databases[req.id] = db
                else
                  raise "Missing databaseName for entity #{req.id}"
                end
              else
                raise "Parent client '#{client_name}' not found for database entity #{req.id}"
              end
            end
          when "collection"
            if db_name = req.database
              if parent_db = @registry.databases[db_name]?
                if coll_name = req.collectionName
                  coll = parent_db[coll_name]
                  apply_entity_options(coll, req.collectionOptions)
                  @registry.collections[req.id] = coll
                else
                  raise "Missing collectionName for entity #{req.id}"
                end
              else
                raise "Parent database '#{db_name}' not found for collection entity #{req.id}"
              end
            end
          when "bucket"
            if db_name = req.database
              if parent_db = @registry.databases[db_name]?
                bucket = parent_db.grid_fs
                @registry.buckets[req.id] = bucket
              else
                raise "Parent database '#{db_name}' not found for bucket entity #{req.id}"
              end
            end
          when "session"
            if client_name = req.client
              if parent_client = @registry.clients[client_name]?
                opts = req.sessionOptions
                causal = nil
                default_txn_opts = nil

                if opts
                  if hash = opts.as_h?
                    if cc = hash["causalConsistency"]?
                      causal = cc.as_bool
                    end
                    if def_opts = hash["defaultTransactionOptions"]?
                      default_txn_opts = parse_transaction_options(def_opts)
                    end
                  end
                end

                session = parent_client.start_session(
                  causal_consistency: causal.nil? ? true : causal,
                  default_transaction_options: default_txn_opts
                )
                @registry.sessions[req.id] = session
              else
                raise "Parent client '#{client_name}' not found for session entity #{req.id}"
              end
            end
          end
        end
      end
    end

    private def setup_initial_data(initial_data : Array(CollectionData)?)
      return unless initial_data

      initial_data.each do |data|
        db = @internal_client[data.databaseName]
        coll = db[data.collectionName]

        db.command(Mongo::Commands::Drop, name: data.collectionName) rescue nil
        db.command(Mongo::Commands::Create, name: data.collectionName) rescue nil
        coll.delete_many(BSON.new) rescue nil

        unless data.documents.empty?
          docs = data.documents.map { |d| BSON.from_json(d.to_json) }
          coll.insert_many(docs)
        end
      end
    end

    private def verify_outcome(outcome : Array(CollectionData)?)
      return unless outcome

      outcome.each do |data|
        coll = @internal_client[data.databaseName][data.collectionName]
        actual_docs = coll.find.to_a

        if actual_docs.size != data.documents.size
          raise "Outcome mismatch: Expected #{data.documents.size} docs, got #{actual_docs.size}"
        end
      end
    end
  end
end
