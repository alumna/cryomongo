require "json"
require "semantic_version"
require "../spec_helper"
require "./schema"
require "./registry"
require "./dispatcher"
require "./matcher"
require "./parse"
require "./timing"

module Mongo::Unified
  class Skip < Exception
  end

  class Runner
    @@mongo_version : SemanticVersion? = nil
    @@topology : String? = nil
    @@shared_client : Mongo::Client? = nil
    @@shared_lock = Sync::Mutex.new
    @@direct_clients = {} of String => Mongo::Client

    @registry = Registry.new
    @test_file : TestFile
    @internal_client : Mongo::Client? = nil
    @skip_reason : String? = nil
    @file_path : String
    @force_observe_sensitive : Bool = false

    property fail_point_active : Bool = false

    # Handshake / auth / session-pool traffic is not part of UTF expectEvents.
    IGNORED_MONITOR_COMMANDS = {
      "hello", "ismaster", "isMaster",
      "saslstart", "saslcontinue", "saslStart", "saslContinue",
      "endsessions", "endSessions",
    }.map(&.downcase).to_set

    # Known holes. Do not un-skip until the file passes.
    # Replica-set topology-lifecycle runs on the 3-member rs0 (3.7 / 3.13).
    SKIP_FILES = Set(String).new

    def initialize(file_path : String)
      @file_path = file_path
      json_data = File.read(file_path)
      @test_file = TestFile.from_json(json_data)

      @force_observe_sensitive = file_path.includes?("redacted-commands")

      # Logging UTF needs SDAM log messages. Other unified SDAM files run;
      # missing ops become SKIP_TEST. minPoolSize pool-ready is 3.1. Monitor
      # hello command / network errors is 3.2. Heartbeat events are 3.3.
      # Handshake backpressure labels are 3.4. interruptInUseConnections is 3.5.
      # Concurrent shutdown stale-generation ignore is 3.6. UTF topology helpers
      # (waitForPrimaryChange / recordTopologyDescription / assertTopologyType)
      # are 3.7. pool-clear-min-pool-size-error auth test runs in 3.10 (URI userinfo).
      # SDAM / CMAP / CLAM logging and official CMAP JSON are 3.11 (done).
      basename = File.basename(file_path)
      if basename.in?(SKIP_FILES)
        @skip_reason = "hardcoded skip"
      end
    end

    # One client for runner setup (drop / insert / fail-point off). Creating a
    # client per JSON file was a large part of the old 25-minute suite time.
    def self.shared_client : Mongo::Client
      if client = @@shared_client
        return client
      end
      @@shared_lock.synchronize do
        @@shared_client ||= begin
          uri = ENV["MONGODB_URI"]
          Mongo::Client.new(mongodb_uri_with(uri, "serverSelectionTimeoutMS=3000"))
        end
      end
    end

    def self.close_shared_client
      @@shared_lock.synchronize do
        @@shared_client.try(&.close)
        @@shared_client = nil
        @@direct_clients.each_value(&.close)
        @@direct_clients.clear
      end
    end

    # One Single-topology client per mongod. Turning off failCommand through
    # the replica-set shared client skips Unknown / paused pools, so leftover
    # failCommand retried the next UTF insert (GitHub squash-merge flake).
    def self.direct_client(address : String) : Mongo::Client
      @@shared_lock.synchronize do
        if client = @@direct_clients[address]?
          return client
        end
      end
      uri = mongodb_uri_direct_address(ENV["MONGODB_URI"], address)
      opened = Mongo::Client.new(mongodb_uri_with(uri, "serverSelectionTimeoutMS=3000"))
      @@shared_lock.synchronize do
        if existing = @@direct_clients[address]?
          opened.close
          return existing
        end
        @@direct_clients[address] = opened
        opened
      end
    end

    private def internal_client : Mongo::Client
      @internal_client || Runner.shared_client
    end

    private def disable_fail_points
      # failCommand is per mongos / per mongod. Use the internal client for the
      # selected server, then a directConnection client for every known address
      # (including Unknown). A paused replica-set pool cannot send mode=off, and
      # leftover failCommand retried insertOne in the next file.
      ic = internal_client
      send_fail_point_off(ic, nil)
      addresses = Set(String).new
      begin
        ic.topology.snapshot.servers.each do |server|
          next if server.type.rs_ghost?
          addresses << server.address
          next if server.type.unknown?
          send_fail_point_off(ic, server)
        end
      rescue
      end
      if seed = mongodb_seed_address(ENV["MONGODB_URI"]? || "")
        addresses << seed
      end
      unless load_balanced_topology?
        addresses.each do |address|
          send_fail_point_off(Runner.direct_client(address), nil)
        rescue
        end
      end
      @fail_point_active = false
    end

    private def load_balanced_topology? : Bool
      mapped = @@topology || Runner.utf_topology_name(ENV["TOPOLOGY"]? || "")
      mapped == "load-balanced"
    end

    private def kill_all_sessions
      ic = internal_client
      seen = Set(String).new
      ic.topology.servers.each do |server|
        next if server.type.unknown? || server.type.rs_ghost?
        next unless seen.add?(server.address)
        begin
          ic.command(Mongo::Commands::KillAllSessions, users: [] of String, server_description: server)
        rescue
        end
      end
      # Each known server already received killAllSessions above.
    end

    private def send_fail_point_off(client : Mongo::Client, server : Mongo::SDAM::ServerDescription?) : Nil
      ["failCommand", "onPrimaryTransactionalWrite", "failGetMoreAfterCursorCheckout"].each do |fp|
        begin
          client.command(
            Mongo::Commands::ConfigureFailPoint,
            database: "admin",
            fail_point: fp,
            mode: "off",
            server_description: server
          )
        rescue
        end
      end
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
      file_started = Time.utc
      Timing.line("START", file: @file_path)

      if reason = @skip_reason
        Timing.line("SKIP", file: @file_path, reason: reason, duration_ms: Timing.elapsed_ms(file_started))
        raise Skip.new(reason)
      end

      # Shared client is created only when we may actually talk to the server.
      Mongo::Logging::Config.max_document_length = 10000
      @internal_client = Runner.shared_client
      detect_deployment

      unless meets_requirements?(@test_file.runOnRequirements)
        Timing.line("SKIP", file: @file_path, reason: "file runOnRequirements not met", duration_ms: Timing.elapsed_ms(file_started))
        raise Skip.new("file runOnRequirements not met")
      end

      executed = 0
      skipped = 0
      client = internal_client

      # One lock for the whole file. A per-test lock still let another file
      # run killAllSessions / failCommand between tests (GitHub replica set,
      # extra insert retries after the per-test lock).
      Mongo::SpecCluster.exclusive do
        @test_file.tests.each do |test|
          test_started = Time.utc
          if (reason = test.skipReason) && ENV["UTF_RUN_SKIPPED"]? != "1"
            skipped += 1
            Timing.line("TEST", file: @file_path, name: test.description, status: "skip", reason: reason, duration_ms: Timing.elapsed_ms(test_started))
            next
          end
          # Needs two mongos serviceIds from one client. roundrobin + health-check
          # still sometimes sends both sockets to one mongos (got extra
          # connectionCreated after pool clear). Skip unless UTF_RUN_TWO_MONGOS=1.
          if test.description == "only connections for a specific serviceId are closed when pools are cleared" && ENV["UTF_RUN_TWO_MONGOS"]? != "1"
            skipped += 1
            Timing.line("TEST", file: @file_path, name: test.description, status: "skip", reason: "needs two serviceIds from HAProxy", duration_ms: Timing.elapsed_ms(test_started))
            next
          end
          # Official CSOT runCursorCommand "failure" cases use blockTimeMS 60 with
          # timeoutMS 100, so a correct iteration timeout does not expire. The
          # matching find tests use 250ms vs 200ms.
          if test.description == "Non-tailable cursor iteration timeoutMS is refreshed for getMore if timeoutMode is iteration - failure" ||
             test.description == "Tailable cursor iteration timeoutMS is refreshed for getMore - failure" ||
             test.description == "Tailable cursor awaitData iteration timeoutMS is refreshed for getMore - failure"
            skipped += 1
            Timing.line("TEST", file: @file_path, name: test.description, status: "skip", reason: "official blockTimeMS is less than timeoutMS", duration_ms: Timing.elapsed_ms(test_started))
            next
          end
          if test.description.includes?("waitQueueSize") || test.description.includes?("waitQueueMultiple")
            skipped += 1
            Timing.line("TEST", file: @file_path, name: test.description, status: "skip", reason: "waitQueueSize / waitQueueMultiple are not implemented", duration_ms: Timing.elapsed_ms(test_started))
            next
          end
          if only = ENV["UTF_TEST"]?
            unless test.description.includes?(only)
              skipped += 1
              next
            end
          end
          unless meets_requirements?(test.runOnRequirements)
            skipped += 1
            Timing.line("TEST", file: @file_path, name: test.description, status: "skip", reason: "runOnRequirements", duration_ms: Timing.elapsed_ms(test_started))
            next
          end

          test_aborted = false

          begin
            disable_fail_points
            # Official runner: kill leftover sessions so a sharded txn that was
            # not aborted does not block the next drop for transactionLifetimeLimitSeconds.
            kill_all_sessions
            create_entities(@test_file.createEntities)

            # Drop leftover collections on the internal client. The test client
            # must keep an empty pool (CMAP) and an unused session pool (txnNumber).
            @registry.collections.each_value do |coll|
              internal_client[coll.database.name].command(Mongo::Commands::Drop, name: coll.name) rescue nil
            end

            setup_initial_data(@test_file.initialData)
            gossip_after_setup

            # Setup (drop/create/insert) must not appear in expectEvents.
            @registry.clear_observed_events

            test.operations.each do |op|
              Dispatcher.execute(op, @registry, client, self)
            end
            verify_outcome(test.outcome)
            verify_events(test.expectEvents)
            verify_log_messages(test.expectLogMessages)
            executed += 1
          rescue e : Skip
            test_aborted = true
            skipped += 1
          rescue e : Exception
            if e.message == "SKIP_TEST"
              test_aborted = true
              skipped += 1
            else
              test_ms = Timing.elapsed_ms(test_started)
              Timing.record_test(@file_path, test.description, test_ms)
              Timing.line("TEST", file: @file_path, name: test.description, status: "error", duration_ms: test_ms)
              file_ms = Timing.elapsed_ms(file_started)
              Timing.record_file(@file_path, file_ms)
              Timing.line("FILE", file: @file_path, status: "error", executed: executed, skipped: skipped, duration_ms: file_ms)
              raise Exception.new("#{test.description}: #{e.message}", cause: e)
            end
          ensure
            disable_fail_points
            kill_all_sessions
            @registry.close_all
            @registry = Registry.new
          end

          test_ms = Timing.elapsed_ms(test_started)
          Timing.record_test(@file_path, test.description, test_ms)
          Timing.line("TEST", file: @file_path, name: test.description, status: (test_aborted ? "skip_op" : "ok"), duration_ms: test_ms)
        end
      end

      file_ms = Timing.elapsed_ms(file_started)
      Timing.record_file(@file_path, file_ms)

      if executed == 0
        Timing.line("SKIP", file: @file_path, reason: "all tests skipped", executed: 0, skipped: skipped, duration_ms: file_ms)
        raise Skip.new("all tests skipped in #{@file_path}")
      end

      Timing.line("FILE", file: @file_path, status: "ok", executed: executed, skipped: skipped, duration_ms: file_ms)
    end

    private def detect_deployment
      return if @@mongo_version && @@topology

      # Ping waits for server selection, so the topology is already known.
      # A fixed 250ms sleep after that only added latency.
      begin
        internal_client.command(Mongo::Commands::Ping)
      rescue
      end

      version = if env_version = ENV["MONGODB_VERSION"]?
                  parse_semver(env_version)
                else
                  begin
                    info = internal_client.command(Mongo::Commands::BuildInfo)
                    parse_semver(info.try(&.version) || "8.0.0")
                  rescue
                    parse_semver("8.0.0")
                  end
                end
      @@mongo_version = version

      @@topology = if env_topology = ENV["TOPOLOGY"]?
                     Runner.utf_topology_name(env_topology)
                   else
                     case internal_client.topology.type
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

    # CI uses TOPOLOGY=standalone. Official UTF files say "single".
    def self.utf_topology_name(value : String) : String
      case value
      when "standalone"    then "single"
      when "replica_set"   then "replicaset"
      when "load_balanced" then "load-balanced"
      else                      value
      end
    end

    private def sharded_uri_for_client(uri : String, use_multiple : Bool?) : String
      topology = @@topology || ENV["TOPOLOGY"]? || ""
      mapped = Runner.utf_topology_name(topology)
      if mapped == "load-balanced"
        return load_balanced_uri(use_multiple)
      end
      return uri unless mapped == "sharded"

      hosts = mongodb_uri_hosts(uri)
      if use_multiple == true
        if hosts.size < 2
          raise Skip.new("useMultipleMongoses requires two mongos hosts in MONGODB_URI")
        end
        uri
      elsif use_multiple == false && hosts.size > 1
        mongodb_uri_single_host(uri, hosts[0])
      else
        uri
      end
    end

    # Load-balanced UTF uses one HAProxy host. MULTI_MONGOS_LB_URI still has one
    # host; the backend has two mongos. loadBalanced=true forbids multiple hosts.
    private def load_balanced_uri(use_multiple : Bool?) : String
      single = ENV["SINGLE_MONGOS_LB_URI"]? || ENV["MONGODB_URI"]
      multi = ENV["MULTI_MONGOS_LB_URI"]? || single
      use_multiple == true ? multi : single
    end

    # CSOT: wait until a data-bearing server exists, up to awaitMinPoolSizeMS.
    private def wait_for_min_pool(client : Mongo::Client, wait_ms : Int32?) : Nil
      return unless wait_ms
      return if wait_ms <= 0
      started = Time.utc
      limit = wait_ms.milliseconds
      while (Time.utc - started) < limit
        if client.topology.servers.any?(&.data_bearing?)
          return
        end
        sleep 10.milliseconds
      end
    end

    private def mongodb_uri_hosts(uri : String) : Array(String)
      rest = uri.split("://", 2)[1]? || ""
      host_part = rest.split('/', 2)[0].split('?', 2)[0]
      host_part.split(',').reject(&.empty?)
    end

    private def mongodb_uri_single_host(uri : String, host : String) : String
      scheme, rest = uri.split("://", 2)
      suffix_idx = rest.index('/') || rest.index('?')
      suffix = suffix_idx ? rest[suffix_idx..] : ""
      "#{scheme}://#{host}#{suffix}"
    end

    private def parse_semver(value : String) : SemanticVersion
      parts = value.split(".")
      while parts.size < 3
        parts << "0"
      end
      SemanticVersion.parse(parts[0..2].join("."))
    end

    # UTF `auth: true` means the URI has userinfo, not that mongod used --auth.
    private def uri_has_credentials? : Bool
      uri = ENV["MONGODB_URI"]? || ""
      rest = uri.split("://", 2)[-1]? || ""
      host_part = rest.split('/', 2)[0]
      host_part.includes?('@')
    end

    private def meets_requirements?(requirements : Array(RunOnRequirement)?) : Bool
      return true if requirements.nil? || requirements.empty?

      mongo_version = @@mongo_version || SemanticVersion.new(8, 0, 0)
      topology = @@topology || Runner.utf_topology_name(ENV["TOPOLOGY"]? || "replicaset")

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
          ok = false unless req.auth == uri_has_credentials?
        end

        if mech = req.authMechanism
          uri = (ENV["MONGODB_URI"]? || "").upcase
          ok = false unless uri.includes?("AUTHMECHANISM=#{mech.upcase}")
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
        if tms = hash["timeoutMS"]?
          ms = tms.as_i64? || tms.as_i?.try(&.to_i64)
          entity.timeout_ms = ms if entity.responds_to?(:timeout_ms=)
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
            if mech = req.uriOptions.try(&.as_h?).try(&.["authMechanism"]?).try(&.as_s?)
              up = mech.upcase
              if up.starts_with?("MONGODB-OIDC") || up == "MONGODB-AWS"
                raise Skip.new("authMechanism #{mech} is out of scope")
              end
            end

            uri = ENV["MONGODB_URI"]
            uri = sharded_uri_for_client(uri, req.useMultipleMongoses)
            uri = mongodb_uri_with(uri, query_parts.join("&")) unless query_parts.empty?

            options = Mongo::Options.new
            if server_api_json = req.serverApi
              options.server_api = Mongo::ServerApi.new(
                version: server_api_json["version"].as_s,
                strict: server_api_json["strict"]?.try(&.as_bool),
                deprecation_errors: server_api_json["deprecationErrors"]?.try(&.as_bool)
              )
            end

            client = Mongo::Client.new(uri, options: options, start_monitoring: false)
            @registry.clients[client_id] = client
            # Local arrays so a closed client's late callback cannot append to
            # the next test's registry (same client id "client", @registry reassigned).
            command_events = [] of Mongo::Monitoring::Commands::Event
            sdam_events = [] of Mongo::Monitoring::SDAM::Event
            cmap_events = [] of Mongo::Monitoring::CMAP::Event
            log_messages = [] of Mongo::Logging::Message
            events_lock = @registry.events_lock
            @registry.command_events[client_id] = command_events
            @registry.sdam_events[client_id] = sdam_events
            @registry.cmap_events[client_id] = cmap_events
            @registry.log_messages[client_id] = log_messages
            ignored = req.ignoreCommandMonitoringEvents.try(&.map(&.downcase)) || [] of String
            @registry.ignored_command_events[client_id] = ignored
            observed = req.observeEvents || [] of String
            observe_sensitive = req.observeSensitiveCommands == true || @force_observe_sensitive

            client.subscribe_commands do |event|
              name = event.command_name.downcase
              # Handshake sasl/hello is not part of UTF expectEvents, except when
              # the test watches sensitive runCommand bodies (redacted-commands).
              next if name == "endsessions"
              unless observe_sensitive
                if name == "hello" || name == "ismaster"
                  # Keep application runCommand hello (not handshake). Handshake uses $db admin.
                  body = event.responds_to?(:command) ? event.command : nil
                  db = body.as?(BSON).try(&.["$db"]?).try(&.as?(String))
                  next if db.nil? || db == "admin"
                elsif IGNORED_MONITOR_COMMANDS.includes?(name)
                  next
                end
              end
              next if ignored.includes?(name)
              unless observe_sensitive
                body = event.responds_to?(:command) ? event.command : nil
                next if Mongo::Monitoring::Redact.sensitive?(event.command_name, body.as?(BSON))
              end
              event_type = case event
                           when Mongo::Monitoring::Commands::CommandStartedEvent   then "commandStartedEvent"
                           when Mongo::Monitoring::Commands::CommandSucceededEvent then "commandSucceededEvent"
                           when Mongo::Monitoring::Commands::CommandFailedEvent    then "commandFailedEvent"
                           else
                             next
                           end
              # UTF: only record types listed in observeEvents. Empty list means no observation.
              next if observed.empty? || !observed.includes?(event_type)
              events_lock.synchronize { command_events << event }
            end

            if observed.any? { |name| name.starts_with?("server") || name.starts_with?("topology") }
              client.subscribe_sdam do |event|
                event_type = case event
                             when Mongo::Monitoring::SDAM::ServerDescriptionChangedEvent   then "serverDescriptionChangedEvent"
                             when Mongo::Monitoring::SDAM::ServerOpeningEvent              then "serverOpeningEvent"
                             when Mongo::Monitoring::SDAM::ServerClosedEvent               then "serverClosedEvent"
                             when Mongo::Monitoring::SDAM::TopologyDescriptionChangedEvent then "topologyDescriptionChangedEvent"
                             when Mongo::Monitoring::SDAM::TopologyOpeningEvent            then "topologyOpeningEvent"
                             when Mongo::Monitoring::SDAM::TopologyClosedEvent             then "topologyClosedEvent"
                             when Mongo::Monitoring::SDAM::ServerHeartbeatStartedEvent     then "serverHeartbeatStartedEvent"
                             when Mongo::Monitoring::SDAM::ServerHeartbeatSucceededEvent   then "serverHeartbeatSucceededEvent"
                             when Mongo::Monitoring::SDAM::ServerHeartbeatFailedEvent      then "serverHeartbeatFailedEvent"
                             else
                               next
                             end
                next unless observed.includes?(event_type)
                events_lock.synchronize { sdam_events << event }
              end
            end

            if observed.any? { |name| name.starts_with?("pool") || name.starts_with?("connection") }
              client.subscribe_cmap do |event|
                event_type = case event
                             when Mongo::Monitoring::CMAP::PoolCreatedEvent               then "poolCreatedEvent"
                             when Mongo::Monitoring::CMAP::PoolReadyEvent                 then "poolReadyEvent"
                             when Mongo::Monitoring::CMAP::PoolClearedEvent               then "poolClearedEvent"
                             when Mongo::Monitoring::CMAP::PoolClosedEvent                then "poolClosedEvent"
                             when Mongo::Monitoring::CMAP::ConnectionCreatedEvent         then "connectionCreatedEvent"
                             when Mongo::Monitoring::CMAP::ConnectionReadyEvent           then "connectionReadyEvent"
                             when Mongo::Monitoring::CMAP::ConnectionClosedEvent          then "connectionClosedEvent"
                             when Mongo::Monitoring::CMAP::ConnectionCheckOutStartedEvent then "connectionCheckOutStartedEvent"
                             when Mongo::Monitoring::CMAP::ConnectionCheckedOutEvent      then "connectionCheckedOutEvent"
                             when Mongo::Monitoring::CMAP::ConnectionCheckedInEvent       then "connectionCheckedInEvent"
                             when Mongo::Monitoring::CMAP::ConnectionCheckOutFailedEvent  then "connectionCheckOutFailedEvent"
                             else
                               next
                             end
                next unless observed.includes?(event_type)
                events_lock.synchronize { cmap_events << event }
              end
            end

            if logs = req.observeLogMessages
              logs.each do |component_name, level_name|
                component = Mongo::Logging::Component.parse_spec(component_name)
                severity = Mongo::Logging::Severity.parse_spec(level_name)
                next unless component && severity
                client.log_sink.subscribe(component, severity) do |msg|
                  events_lock.synchronize { log_messages << msg }
                end
              end
            end

            # Spec: subscribe before connect. Flush constructor SDAM events, then scan.
            client.start_sdam_monitoring
            wait_for_min_pool(client, req.awaitMinPoolSizeMS)
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
                bucket_name = "fs"
                chunk = 255 * 1024
                if opts = req.bucketOptions.try(&.as_h?)
                  if n = opts["bucketName"]?.try(&.as_s?)
                    bucket_name = n
                  end
                  if c = opts["chunkSizeBytes"]?
                    chunk = c.as_i? || c.as_i64?.try(&.to_i32) || chunk
                  end
                end
                bucket = parent_db.grid_fs(bucket_name, chunk_size_bytes: chunk)
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
                default_timeout_ms = nil

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
                    if tms = hash["defaultTimeoutMS"]?
                      default_timeout_ms = tms.as_i64? || tms.as_i?.try(&.to_i64)
                    end
                  end
                end

                session = parent_client.start_session(
                  causal_consistency: causal,
                  snapshot: snapshot,
                  snapshot_time: snapshot_time,
                  default_transaction_options: default_txn_opts,
                  default_timeout_ms: default_timeout_ms
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

    private def gossip_after_setup
      # Drop/create can leave a mongos catalog cache stale (SERVER-39704).
      # Touch each mongos on the internal client only. Entity clients must not
      # get extra connections (CMAP tests) or extra implicit sessions (txnNumber).
      servers = begin
        internal_client.topology.servers.dup
      rescue
        [] of Mongo::SDAM::ServerDescription
      end

      data_sets = @test_file.initialData
      if data_sets && !data_sets.empty? && !servers.empty?
        data_sets.each do |data|
          servers.each do |server|
            begin
              internal_client.command(
                Mongo::Commands::Distinct,
                database: data.databaseName,
                collection: data.collectionName,
                key: "_id",
                server_description: server,
                options: {query: BSON.new}
              )
            rescue
            end
          end
        end
      else
        servers.each do |server|
          begin
            internal_client.command(Mongo::Commands::Ping, server_description: server)
          rescue
          end
        end
      end

      if ct = internal_client.cluster_time
        @registry.clients.each_value { |c| c.advance_cluster_time(ct) }
        @registry.sessions.each_value { |s| s.advance_cluster_time(ct) }
      end
    end

    private def setup_initial_data(initial_data : Array(CollectionData)?)
      return unless initial_data

      # Separate client so setup does not fill the test client's session pool
      # (implicit retryable writes would leave txnNumber > 0).
      client = internal_client
      # Majority so mongos catalog and snapshot reads see the new collection.
      majority = Mongo::WriteConcern.new(w: "majority")

      initial_data.each do |data|
        db = client[data.databaseName]
        coll = db[data.collectionName]

        db.command(Mongo::Commands::Drop, name: data.collectionName, write_concern: majority) rescue nil
        if co = data.createOptions.try(&.as_h?)
          capped = co["capped"]?.try(&.as_bool)
          size = co["size"]?.try { |s| s.as_i? || s.as_i64?.try(&.to_i32) }
          max = co["max"]?.try { |s| s.as_i? || s.as_i64?.try(&.to_i32) }
          db.command(Mongo::Commands::Create, name: data.collectionName, write_concern: majority, options: {
            capped: capped,
            size:   size,
            max:    max,
          }) rescue nil
        else
          db.command(Mongo::Commands::Create, name: data.collectionName, write_concern: majority) rescue nil
        end

        unless data.documents.empty?
          docs = data.documents.map { |d| BSON.from_json(d.to_json) }
          coll.insert_many(docs, write_concern: majority)
        end
      end
    end

    private def verify_outcome(outcome : Array(CollectionData)?)
      return unless outcome

      outcome.each do |data|
        coll = internal_client[data.databaseName][data.collectionName]
        # Official UTF: sort {_id: 1} so outcome order is stable.
        actual_docs = coll.find(sort: {_id: 1}).to_a

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
        event_type = hash["eventType"]?.try(&.as_s?) || "command"
        if event_type == "cmap"
          verify_cmap_events(client_id, expected_events, hash["ignoreExtraEvents"]?.try(&.as_bool) || false)
          next
        elsif event_type == "sdam"
          verify_sdam_events(client_id, expected_events, hash["ignoreExtraEvents"]?.try(&.as_bool) || false)
          next
        end
        actual_events = @registry.snapshot_command_events(client_id)

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
            check_has_service_id!(expected_started, actual, index)
            check_has_server_connection_id!(expected_started, actual, index)
            if db_name = expected_started["databaseName"]?
              unless db_name.as_s == actual.database_name
                raise Exception.new("TEST_FAILED: event #{index} databaseName expected #{db_name.as_s}, got #{actual.database_name}")
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
            check_has_service_id!(expected_succeeded, actual, index)
            check_has_server_connection_id!(expected_succeeded, actual, index)
            if reply = expected_succeeded["reply"]?
              actual_reply = JSON.parse(actual.reply.to_canonical_extjson)
              unless Matcher.matches?(reply, actual_reply, @registry)
                raise Exception.new("TEST_FAILED: event #{index} reply mismatch: expected #{reply.inspect}, got #{actual_reply.inspect}")
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
            check_has_service_id!(expected_failed, actual, index)
            check_has_server_connection_id!(expected_failed, actual, index)
            if reply = expected_failed["reply"]?
              actual_reply = JSON.parse(actual.reply.to_canonical_extjson)
              unless Matcher.matches?(reply, actual_reply, @registry)
                raise Exception.new("TEST_FAILED: event #{index} failed reply mismatch: expected #{reply.inspect}, got #{actual_reply.inspect}")
              end
            end
          end
        end
      end
    end

    private def check_has_server_connection_id!(expected : JSON::Any, actual, index : Int32) : Nil
      return unless expected["hasServerConnectionId"]?
      want = expected["hasServerConnectionId"].as_bool
      has = false
      if actual.responds_to?(:server_connection_id)
        if id = actual.server_connection_id
          has = id > 0
        end
      end
      unless has == want
        raise Exception.new("TEST_FAILED: event #{index} hasServerConnectionId expected #{want}, got #{has}")
      end
    end

    private def check_has_service_id!(expected : JSON::Any, actual, index : Int32) : Nil
      return unless expected["hasServiceId"]?
      want = expected["hasServiceId"].as_bool
      has = false
      if actual.responds_to?(:service_id)
        has = !actual.service_id.nil?
      end
      unless has == want
        raise Exception.new("TEST_FAILED: event #{index} hasServiceId expected #{want}, got #{has}")
      end
    end

    private def verify_sdam_events(client_id : String, expected_events : Array(JSON::Any), ignore_extra : Bool)
      actual = @registry.snapshot_sdam_events(client_id)
      if actual.size < expected_events.size
        names = actual.map(&.class.name)
        raise Exception.new("TEST_FAILED: expected at least #{expected_events.size} sdam events for #{client_id}, got #{actual.size}: #{names}")
      end
      unless ignore_extra || actual.size == expected_events.size
        names = actual.map(&.class.name)
        raise Exception.new("TEST_FAILED: expected #{expected_events.size} sdam events for #{client_id}, got #{actual.size}: #{names}")
      end
      expected_events.each_with_index do |expected, index|
        actual_event = actual[index]
        unless sdam_event_matches?(actual_event, expected)
          raise Exception.new("TEST_FAILED: sdam event #{index} expected #{expected.as_h.keys.first}, got #{actual_event.class}")
        end
      end
    end

    private def sdam_event_matches?(actual : Mongo::Monitoring::SDAM::Event, expected : JSON::Any) : Bool
      if body = expected["serverHeartbeatStartedEvent"]?
        return actual.is_a?(Mongo::Monitoring::SDAM::ServerHeartbeatStartedEvent) && Matcher.heartbeat_awaited?(actual.awaited, body)
      end
      if body = expected["serverHeartbeatSucceededEvent"]?
        return actual.is_a?(Mongo::Monitoring::SDAM::ServerHeartbeatSucceededEvent) && Matcher.heartbeat_awaited?(actual.awaited, body)
      end
      if body = expected["serverHeartbeatFailedEvent"]?
        return actual.is_a?(Mongo::Monitoring::SDAM::ServerHeartbeatFailedEvent) && Matcher.heartbeat_awaited?(actual.awaited, body)
      end
      if expected["topologyOpeningEvent"]?
        return actual.is_a?(Mongo::Monitoring::SDAM::TopologyOpeningEvent)
      end
      if expected["topologyClosedEvent"]?
        return actual.is_a?(Mongo::Monitoring::SDAM::TopologyClosedEvent)
      end
      if body = expected["topologyDescriptionChangedEvent"]?
        return false unless actual.is_a?(Mongo::Monitoring::SDAM::TopologyDescriptionChangedEvent)
        if prev = body["previousDescription"]?
          return false unless topology_description_match?(actual.previous_description, prev)
        end
        if nxt = body["newDescription"]?
          return false unless topology_description_match?(actual.new_description, nxt)
        end
        return true
      end
      if expected["serverOpeningEvent"]?
        return actual.is_a?(Mongo::Monitoring::SDAM::ServerOpeningEvent)
      end
      if expected["serverClosedEvent"]?
        return actual.is_a?(Mongo::Monitoring::SDAM::ServerClosedEvent)
      end
      if body = expected["serverDescriptionChangedEvent"]?
        return false unless actual.is_a?(Mongo::Monitoring::SDAM::ServerDescriptionChangedEvent)
        if new_desc = body["newDescription"]?
          if type = new_desc["type"]?.try(&.as_s?)
            return false unless actual.new_description.type.to_s == type
          end
        end
        if prev_desc = body["previousDescription"]?
          if type = prev_desc["type"]?.try(&.as_s?)
            return false unless actual.previous_description.type.to_s == type
          end
        end
        return true
      end
      false
    end

    private def topology_description_match?(actual : Mongo::SDAM::TopologyDescription, expected : JSON::Any) : Bool
      if type = expected["type"]?.try(&.as_s?)
        return actual.type.to_s == type
      end
      true
    end

    private def verify_cmap_events(client_id : String, expected_events : Array(JSON::Any), ignore_extra : Bool)
      actual = @registry.snapshot_cmap_events(client_id)
      unless ignore_extra || actual.size == expected_events.size
        names = actual.map(&.class.name)
        raise Exception.new("TEST_FAILED: expected #{expected_events.size} cmap events for #{client_id}, got #{actual.size}: #{names}")
      end
      expected_events.each_with_index do |expected, index|
        break if index >= actual.size
        actual_event = actual[index]
        if expected["poolCreatedEvent"]?
          unless actual_event.is_a?(Mongo::Monitoring::CMAP::PoolCreatedEvent)
            raise Exception.new("TEST_FAILED: cmap event #{index} expected poolCreatedEvent, got #{actual_event.class}")
          end
        elsif expected["poolReadyEvent"]?
          unless actual_event.is_a?(Mongo::Monitoring::CMAP::PoolReadyEvent)
            raise Exception.new("TEST_FAILED: cmap event #{index} expected poolReadyEvent, got #{actual_event.class}")
          end
        elsif expected["connectionCreatedEvent"]?
          unless actual_event.is_a?(Mongo::Monitoring::CMAP::ConnectionCreatedEvent)
            raise Exception.new("TEST_FAILED: cmap event #{index} expected connectionCreatedEvent, got #{actual_event.class}")
          end
        elsif expected["connectionReadyEvent"]?
          unless actual_event.is_a?(Mongo::Monitoring::CMAP::ConnectionReadyEvent)
            raise Exception.new("TEST_FAILED: cmap event #{index} expected connectionReadyEvent, got #{actual_event.class}")
          end
        elsif body = expected["connectionClosedEvent"]?
          unless actual_event.is_a?(Mongo::Monitoring::CMAP::ConnectionClosedEvent)
            raise Exception.new("TEST_FAILED: cmap event #{index} expected connectionClosedEvent, got #{actual_event.class}")
          end
          if reason = body["reason"]?.try(&.as_s?)
            unless actual_event.reason == reason
              raise Exception.new("TEST_FAILED: cmap event #{index} connectionClosedEvent reason expected #{reason}, got #{actual_event.reason}")
            end
          end
        elsif body = expected["poolClearedEvent"]?
          unless actual_event.is_a?(Mongo::Monitoring::CMAP::PoolClearedEvent)
            raise Exception.new("TEST_FAILED: cmap event #{index} expected poolClearedEvent, got #{actual_event.class}")
          end
          check_has_service_id!(body, actual_event, index)
          if body["interruptInUseConnections"]?
            want = body["interruptInUseConnections"].as_bool
            unless actual_event.interrupt_in_use_connections == want
              raise Exception.new("TEST_FAILED: cmap event #{index} poolClearedEvent interruptInUseConnections expected #{want}, got #{actual_event.interrupt_in_use_connections}")
            end
          end
        elsif expected["connectionCheckedOutEvent"]?
          unless actual_event.is_a?(Mongo::Monitoring::CMAP::ConnectionCheckedOutEvent)
            raise Exception.new("TEST_FAILED: cmap event #{index} expected connectionCheckedOutEvent, got #{actual_event.class}")
          end
        elsif expected["connectionCheckedInEvent"]?
          unless actual_event.is_a?(Mongo::Monitoring::CMAP::ConnectionCheckedInEvent)
            raise Exception.new("TEST_FAILED: cmap event #{index} expected connectionCheckedInEvent, got #{actual_event.class}")
          end
        elsif body = expected["connectionCheckOutFailedEvent"]?
          unless actual_event.is_a?(Mongo::Monitoring::CMAP::ConnectionCheckOutFailedEvent)
            raise Exception.new("TEST_FAILED: cmap event #{index} expected connectionCheckOutFailedEvent, got #{actual_event.class}")
          end
          if reason = body["reason"]?.try(&.as_s?)
            unless actual_event.reason == reason
              raise Exception.new("TEST_FAILED: cmap event #{index} connectionCheckOutFailedEvent reason expected #{reason}, got #{actual_event.reason}")
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
      result = internal_client["admin"].run_command(BSON.new({"getParameter" => 1, name => 1}))
      return nil unless result
      if value = result[name]?
        Matcher.json_from(value)
      end
    rescue
      nil
    end

    private def verify_log_messages(expected : JSON::Any?) : Nil
      return unless expected
      expected.as_a.each do |group|
        client_id = group["client"].as_s
        ignore_extra = group["ignoreExtraMessages"]?.try(&.as_bool) || false
        ignore = group["ignoreMessages"]?.try(&.as_a) || [] of JSON::Any
        wanted = group["messages"].as_a
        actual = @registry.snapshot_log_messages(client_id)
        actual.reject! { |msg| ignore.any? { |pattern| Matcher.matches?(pattern, log_message_json(msg), @registry) } }

        wanted.each_with_index do |expected_msg, index|
          if index >= actual.size
            names = actual.map { |m| m.data["message"]?.try(&.as_s) || m.component.spec_name }
            raise Exception.new("TEST_FAILED: expected at least #{wanted.size} log messages for #{client_id}, got #{actual.size}: #{names}")
          end
          unless log_message_matches?(expected_msg, actual[index])
            raise Exception.new("TEST_FAILED: log message #{index} for #{client_id} expected #{expected_msg.inspect}, got #{log_message_json(actual[index]).inspect}")
          end
        end
        unless ignore_extra || actual.size == wanted.size
          names = actual.map { |m| m.data["message"]?.try(&.as_s) || m.component.spec_name }
          raise Exception.new("TEST_FAILED: expected #{wanted.size} log messages for #{client_id}, got #{actual.size}: #{names}")
        end
      end
    end

    private def log_message_json(msg : Mongo::Logging::Message) : JSON::Any
      JSON::Any.new({
        "level"     => JSON::Any.new(msg.severity.spec_name),
        "component" => JSON::Any.new(msg.component.spec_name),
        "data"      => JSON::Any.new(msg.data),
      } of String => JSON::Any)
    end

    private def log_message_matches?(expected : JSON::Any, actual : Mongo::Logging::Message) : Bool
      if level = expected["level"]?.try(&.as_s?)
        return false unless level == actual.severity.spec_name
      end
      if component = expected["component"]?.try(&.as_s?)
        return false unless component == actual.component.spec_name
      end
      if data = expected["data"]?
        return false unless Matcher.matches?(data, JSON::Any.new(actual.data), @registry)
      end
      if expected["failureIsRedacted"]?
        want_redacted = expected["failureIsRedacted"].as_bool
        failure = actual.data["failure"]?
        return false unless failure
        text = failure.as_s? || failure.to_json
        if want_redacted
          text == "REDACTED" || text == "{}" || text.empty?
        else
          !text.empty? && text != "REDACTED"
        end
      else
        true
      end
    end
  end
end
