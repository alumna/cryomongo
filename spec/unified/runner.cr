require "json"
require "semantic_version"
require "../../src/cryomongo"
require "./schema"
require "./registry"
require "./dispatcher"
require "./matcher"
require "./parse"

module Mongo::Unified
  class Skip < Exception
  end

  class Runner
    @@mongo_version : SemanticVersion? = nil
    @@topology : String? = nil

    @registry = Registry.new
    @test_file : TestFile
    @internal_client : Mongo::Client
    @skip_reason : String? = nil
    @file_path : String

    property fail_point_active : Bool = false

    # Handshake / auth / session-pool traffic is not part of UTF expectEvents.
    IGNORED_MONITOR_COMMANDS = {
      "hello", "ismaster", "isMaster",
      "saslstart", "saslcontinue", "saslStart", "saslContinue",
      "endsessions", "endSessions",
    }.map(&.downcase).to_set

    def initialize(file_path : String)
      @file_path = file_path
      json_data = File.read(file_path)
      @test_file = TestFile.from_json(json_data)
      uri = ENV["MONGODB_URI"]
      separator = uri.includes?("?") ? "&" : "?"
      @internal_client = Mongo::Client.new("#{uri}#{separator}serverSelectionTimeoutMS=3000")

      @skip_reason = "hardcoded skip" if file_path.ends_with?("create-null-ids.json") ||
                                         file_path.includes?("backpressure-") ||
                                         file_path.ends_with?("rediscover-quickly-after-step-down.json") ||
                                         file_path.ends_with?("interruptInUse-pool-clear.json")
    end

    private def disable_fail_points
      return unless @fail_point_active == true

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

      @fail_point_active = false
    end

    private def parse_transaction_options(opts : JSON::Any?) : Mongo::Session::TransactionOptions?
      return nil unless opts
      if hash = opts.as_h?
        rc = hash["readConcern"]?.try { |v| Parse.read_concern(v) }
        wc = hash["writeConcern"]?.try { |v| Parse.write_concern(v) }
        rp = hash["readPreference"]?.try { |v| Parse.read_preference(v) }
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
      raise Skip.new(@skip_reason || "skipped") if @skip_reason
      detect_deployment
      raise Skip.new("file runOnRequirements not met") unless meets_requirements?(@test_file.runOnRequirements)

      executed = 0
      skipped = 0

      @test_file.tests.each do |test|
        if reason = test.skipReason
          skipped += 1
          next
        end
        unless meets_requirements?(test.runOnRequirements)
          skipped += 1
          next
        end

        disable_fail_points

        create_entities(@test_file.createEntities)

        # Do not delete this.
        # Collections can be created dynamically by tests and they
        # also need to be deleted, not only the explicit ones.
        @registry.collections.each_value do |coll|
          coll.database.command(Mongo::Commands::Drop, name: coll.name) rescue nil
        end

        setup_initial_data(@test_file.initialData)

        # Setup (drop/create/insert) must not appear in expectEvents.
        @registry.command_events.each_value(&.clear)

        test_aborted = false

        begin
          test.operations.each do |op|
            Dispatcher.execute(op, @registry, @internal_client, self)
          end
        rescue e : Exception
          if e.message == "SKIP_TEST"
            test_aborted = true
            skipped += 1
          else
            raise e
          end
        end

        unless test_aborted
          verify_outcome(test.outcome)
          verify_events(test.expectEvents)
          executed += 1
        end

        disable_fail_points
        @registry.close_all
        @registry = Registry.new
      end

      raise Skip.new("all tests skipped in #{@file_path}") if executed == 0
    ensure
      @internal_client.close
    end

    private def detect_deployment
      return if @@mongo_version && @@topology

      begin
        @internal_client.command(Mongo::Commands::Ping)
      rescue
      end
      sleep 250.milliseconds

      version = parse_semver(ENV["MONGODB_VERSION"]? || "8.0.29")
      @@mongo_version = version

      @@topology = ENV["TOPOLOGY"]? || begin
        case @internal_client.topology.type
        when .replica_set_with_primary?, .replica_set_no_primary?
          "replicaset"
        when .sharded?
          "sharded"
        when .load_balanced?
          "load-balanced"
        when .single?
          "single"
        else
          "single"
        end
      end
    end

    private def parse_semver(value : String) : SemanticVersion
      parts = value.split(".")
      while parts.size < 3
        parts << "0"
      end
      SemanticVersion.parse(parts[0..2].join("."))
    end

    private def meets_requirements?(requirements : Array(RunOnRequirement)?) : Bool
      return true if requirements.nil? || requirements.empty?

      mongo_version = @@mongo_version || SemanticVersion.new(8, 0, 0)
      topology = @@topology || ENV["TOPOLOGY"]? || "replicaset"

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
          ok = false unless tops.includes?(topology)
        end

        if !req.auth.nil?
          ok = false if req.auth == true
        end

        if req.serverless == "require"
          ok = false
        end

        if params = req.serverParameters.try(&.as_h?)
          params.each do |name, expected|
            unless server_parameter_matches?(name, expected)
              ok = false
            end
          end
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
          entity.write_concern = Parse.write_concern(wc)
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
            client_id = req.id || raise "Missing id"
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

            options = Mongo::Options.new
            if server_api_json = req.serverApi
              options.server_api = Mongo::ServerApi.new(
                version: server_api_json["version"].as_s,
                strict: server_api_json["strict"]?.try(&.as_bool),
                deprecation_errors: server_api_json["deprecationErrors"]?.try(&.as_bool)
              )
            end

            client = Mongo::Client.new(uri, options: options)
            @registry.clients[client_id] = client
            @registry.command_events[client_id] = [] of Mongo::Monitoring::Commands::Event
            ignored = req.ignoreCommandMonitoringEvents.try(&.map(&.downcase)) || [] of String
            @registry.ignored_command_events[client_id] = ignored
            observed = req.observeEvents || [] of String

            client.subscribe_commands do |event|
              name = event.command_name.downcase
              next if IGNORED_MONITOR_COMMANDS.includes?(name)
              next if ignored.includes?(name)
              event_type = case event
                           when Mongo::Monitoring::Commands::CommandStartedEvent   then "commandStartedEvent"
                           when Mongo::Monitoring::Commands::CommandSucceededEvent then "commandSucceededEvent"
                           when Mongo::Monitoring::Commands::CommandFailedEvent    then "commandFailedEvent"
                           else
                             next
                           end
              # UTF: only record types listed in observeEvents. Empty list means no observation.
              next if observed.empty? || !observed.includes?(event_type)
              @registry.command_events[client_id] << event
            end
          when "database"
            db_id = req.id || raise "Missing database id"
            if client_name = req.client
              if parent_client = @registry.clients[client_name]?
                if db_name = req.databaseName
                  db = parent_client[db_name]
                  apply_entity_options(db, req.databaseOptions)
                  @registry.databases[db_id] = db
                else
                  raise "Missing databaseName for entity #{db_id}"
                end
              else
                raise "Parent client '#{client_name}' not found for database entity #{db_id}"
              end
            end
          when "collection"
            coll_id = req.id || raise "Missing collection id"
            if db_name = req.database
              if parent_db = @registry.databases[db_name]?
                if coll_name = req.collectionName
                  coll = parent_db[coll_name]
                  apply_entity_options(coll, req.collectionOptions)
                  @registry.collections[coll_id] = coll
                else
                  raise "Missing collectionName for entity #{coll_id}"
                end
              else
                raise "Parent database '#{db_name}' not found for collection entity #{coll_id}"
              end
            end
          when "bucket"
            bucket_id = req.id || raise "Missing bucket id"
            if db_name = req.database
              if parent_db = @registry.databases[db_name]?
                bucket = parent_db.grid_fs
                @registry.buckets[bucket_id] = bucket
              else
                raise "Parent database '#{db_name}' not found for bucket entity #{bucket_id}"
              end
            end
          when "session"
            session_id = req.id || raise "Missing session id"
            if client_name = req.client
              if parent_client = @registry.clients[client_name]?
                opts = req.sessionOptions
                causal = nil
                snapshot = nil
                snapshot_time = nil
                default_txn_opts = nil

                if opts
                  if hash = opts.as_h?
                    if cc = hash["causalConsistency"]?
                      causal = cc.as_bool
                    end
                    if snap = hash["snapshot"]?
                      snapshot = snap.as_bool
                    end
                    if snap_time_arg = hash["snapshotTime"]?
                      if snap_time_str = snap_time_arg.as_s?
                        if val = @registry.entities[snap_time_str]?
                          snapshot_time = val.as?(BSON::Timestamp)
                        end
                      end
                    end
                    if def_opts = hash["defaultTransactionOptions"]?
                      default_txn_opts = parse_transaction_options(def_opts)
                    end
                  end
                end

                session = parent_client.start_session(
                  causal_consistency: causal,
                  snapshot: snapshot,
                  snapshot_time: snapshot_time,
                  default_transaction_options: default_txn_opts
                )
                @registry.sessions[session_id] = session
              else
                raise "Parent client '#{client_name}' not found for session entity #{session_id}"
              end
            end
          when "thread"
            thread_id = req.thread.try(&.id) || req.id || raise "Missing thread id"
            @registry.threads[thread_id] = Channel(Exception?).new
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

        unless Matcher.documents_match?(data.documents, actual_docs)
          raise Exception.new("TEST_FAILED: outcome mismatch for #{data.databaseName}.#{data.collectionName}: expected #{data.documents.inspect}, got #{actual_docs.map(&.to_canonical_extjson)}")
        end
      end
    end

    private def verify_events(expect_events : JSON::Any?)
      return unless expect_events
      return unless event_groups = expect_events.as_a?

      event_groups.each do |group|
        hash = group.as_h
        client_id = hash["client"].as_s
        expected_events = hash["events"].as_a
        actual_events = (@registry.command_events[client_id]? || [] of Mongo::Monitoring::Commands::Event).dup

        expected_names = expected_events.compact_map { |event|
          started = event["commandStartedEvent"]?
          succeeded = event["commandSucceededEvent"]?
          failed = event["commandFailedEvent"]?
          started.try(&.["commandName"]?).try(&.as_s?) ||
            succeeded.try(&.["commandName"]?).try(&.as_s?) ||
            failed.try(&.["commandName"]?).try(&.as_s?) ||
            started.try(&.["command"]?).try(&.as_h?).try { |cmd|
              if cmd.has_key?("getMore")
                "getMore"
              elsif cmd.has_key?("killCursors")
                "killCursors"
              elsif cmd.has_key?("configureFailPoint")
                "configureFailPoint"
              end
            }
        }
        # Cursor exhaustion / cleanup is not listed in most UTF expectEvents.
        unless expected_names.includes?("getMore")
          actual_events.reject! { |event| event.command_name == "getMore" }
        end
        unless expected_names.includes?("killCursors")
          actual_events.reject! { |event| event.command_name == "killCursors" }
        end
        unless expected_names.includes?("configureFailPoint")
          actual_events.reject! { |event| event.command_name == "configureFailPoint" }
        end

        ignore = hash["ignoreExtraEvents"]?.try(&.as_bool) || false
        unless ignore || actual_events.size == expected_events.size
          names = actual_events.map(&.command_name)
          raise Exception.new("TEST_FAILED: expected #{expected_events.size} events for #{client_id}, got #{actual_events.size}: #{names}")
        end

        expected_events.each_with_index do |expected, index|
          break if index >= actual_events.size
          actual = actual_events[index]
          if expected_started = expected["commandStartedEvent"]?
            unless actual.is_a?(Mongo::Monitoring::Commands::CommandStartedEvent)
              raise Exception.new("TEST_FAILED: event #{index} expected commandStartedEvent, got #{actual.class}")
            end
            if name = expected_started["commandName"]?
              unless name.as_s == actual.command_name
                raise Exception.new("TEST_FAILED: event #{index} commandName expected #{name.as_s}, got #{actual.command_name}")
              end
            end
            if command = expected_started["command"]?
              actual_command = JSON.parse(actual.command.to_canonical_extjson)
              unless Matcher.matches?(command, actual_command, @registry)
                raise Exception.new("TEST_FAILED: event #{index} command mismatch: expected #{command.inspect}, got #{actual_command.inspect}")
              end
            end
          elsif expected_succeeded = expected["commandSucceededEvent"]?
            unless actual.is_a?(Mongo::Monitoring::Commands::CommandSucceededEvent)
              raise Exception.new("TEST_FAILED: event #{index} expected commandSucceededEvent, got #{actual.class}")
            end
            if name = expected_succeeded["commandName"]?
              unless name.as_s == actual.command_name
                raise Exception.new("TEST_FAILED: event #{index} commandName expected #{name.as_s}, got #{actual.command_name}")
              end
            end
          elsif expected_failed = expected["commandFailedEvent"]?
            unless actual.is_a?(Mongo::Monitoring::Commands::CommandFailedEvent)
              raise Exception.new("TEST_FAILED: event #{index} expected commandFailedEvent, got #{actual.class}")
            end
            if name = expected_failed["commandName"]?
              unless name.as_s == actual.command_name
                raise Exception.new("TEST_FAILED: event #{index} commandName expected #{name.as_s}, got #{actual.command_name}")
              end
            end
          end
        end
      end
    end

    private def server_parameter_matches?(name : String, expected : JSON::Any) : Bool
      actual = fetch_server_parameter(name)
      if actual.nil?
        # Absent parameters treated as the server default (typically false).
        if expected.raw.is_a?(Bool)
          return expected.as_bool == false
        end
        return false
      end
      Matcher.matches?(expected, actual)
    end

    private def fetch_server_parameter(name : String) : JSON::Any?
      result = @internal_client.command(
        Operations::RawCommand.new("getParameter"),
        database: "admin",
        command_bson: BSON.new({"getParameter" => 1, name => 1})
      )
      return nil unless result
      if value = result[name]?
        Matcher.json_from(value)
      end
    rescue
      nil
    end
  end
end
