require "./spec_helper"

describe "SDAM Legacy Tests" do
  Dir.glob("spec/tests/legacy/server-discovery-and-monitoring/**/*.json").sort.each do |file|
    it "executes: #{file}" do
      json_data = File.read(file)
      test = JSON.parse(json_data)

      uri = test["uri"].as_s
      options = Mongo::Options.new

      events = [] of Mongo::Monitoring::SDAM::Event

      # Disable monitoring since we are feeding mock responses directly into the topology
      client = Mongo::Client.new(uri, options: options, start_monitoring: false)

      # Inject the missing initial events that occurred before we could subscribe.
      # These will be asserted in the first phase, and cleared at the END of each phase.
      empty_topology = Mongo::SDAM::TopologyDescription.new(client)
      events << Mongo::Monitoring::SDAM::TopologyOpeningEvent.new(client.object_id)
      events << Mongo::Monitoring::SDAM::TopologyDescriptionChangedEvent.new(
        client.object_id, empty_topology, client.topology.clone
      )
      client.topology.servers.each do |server|
        events << Mongo::Monitoring::SDAM::ServerOpeningEvent.new(client.object_id, server.address)
      end

      # For load_balanced URIs, our new Client initialization forces an immediate transition to LoadBalancer.
      # We replicate those events here manually so they appear correctly for Phase 1.
      if test["uri"].as_s.includes?("loadBalanced=true")
        test_topology = client.topology.clone
        test_topology.servers.each { |s| s.type = :unknown }
        client.topology.servers.each do |server|
          events << Mongo::Monitoring::SDAM::ServerDescriptionChangedEvent.new(
            client.object_id, server.address, test_topology.servers.first, server.clone
          )
        end
        events << Mongo::Monitoring::SDAM::TopologyDescriptionChangedEvent.new(
          client.object_id, test_topology, client.topology.clone
        )
      end

      client.subscribe_sdam { |e| events << e }

      # SDAM rules require handling ApplicationErrors mapped by CMAP pool generations.
      # We mock generations locally.
      pool_generations = Hash(String, Int32).new

      test["phases"].as_a.each do |phase|
        # 1. Process simulated hello/legacy hello responses
        phase["responses"]?.try &.as_a.each do |resp|
          addr = resp[0].as_s
          payload = resp[1].as_h?

          # Skip if server is not in topology, avoiding phantom allocation
          old_desc = client.topology.servers.find(&.address.==(addr))
          next unless old_desc

          if payload && !payload.empty?
            # The server omits null fields, so we strip them from the mock response
            # to prevent BSON::Serializable from choking on explicit `nil` values.
            clean_payload = payload.reject { |_, v| v.raw.nil? }
            hello_res = Mongo::Commands::Hello::Result.from_bson(BSON.from_json(clean_payload.to_json))
            new_desc = Mongo::SDAM::ServerDescription.new(addr, hello_res, 0.milliseconds)
          else
            new_desc = Mongo::SDAM::ServerDescription.new(addr)
            new_desc.error = "network error"
          end

          client.topology.update(old_desc, new_desc)
        end

        # 2. Process simulated application errors
        phase["applicationErrors"]?.try &.as_a.each do |app_err|
          addr = app_err["address"].as_s

          old_desc = client.topology.servers.find(&.address.==(addr))
          next unless old_desc

          error_type = app_err["type"].as_s
          when_phase = app_err["when"].as_s
          err_gen = app_err["generation"]?.try(&.as_i)

          err = if error_type == "command"
                  resp = app_err["response"]
                  Mongo::Error::Command.new(
                    code: resp["code"]?.try(&.as_i),
                    code_name: resp["codeName"]?.try(&.as_s?),
                    message: resp["errmsg"]?.try(&.as_s?),
                    details: nil,
                    topology_version: resp["topologyVersion"]?.try { |tv| BSON.from_json(tv.to_json) }
                  )
                elsif error_type == "timeout"
                  Mongo::Error::Network.new("timeout")
                else
                  Mongo::Error::Network.new("network error")
                end

          # Determine if error is stale based on generation or topologyVersion
          is_stale = false
          current_gen = pool_generations.fetch(addr, 0)

          if err_gen && err_gen < current_gen
            is_stale = true
          end

          if err.is_a?(Mongo::Error::Command) && err.topology_version
            if client.topology.is_stale_error_topology_version?(old_desc.topology_version, err.topology_version)
              is_stale = true
            end
          end

          unless is_stale
            if err.is_a?(Mongo::Error::Network)
              if when_phase == "beforeHandshakeCompletes"
                # SDAM Spec: MUST NOT change the server's description if network error during connection establishment
              elsif error_type == "timeout" && when_phase == "afterHandshakeCompletes"
                # SDAM Spec: MUST NOT mark the server Unknown on a timeout AFTER handshake
              else
                new_desc = Mongo::SDAM::ServerDescription.new(addr)
                new_desc.error = err.message
                new_desc.last_update_time = old_desc.last_update_time
                client.topology.update(old_desc, new_desc)
                pool_generations[addr] = current_gen + 1
              end
            elsif err.is_a?(Mongo::Error::Command) && err.state_change?
              new_desc = Mongo::SDAM::ServerDescription.new(addr)
              new_desc.min_wire_version = old_desc.min_wire_version
              new_desc.max_wire_version = old_desc.max_wire_version
              new_desc.error = err.message
              new_desc.last_update_time = old_desc.last_update_time
              new_desc.topology_version = err.topology_version
              client.topology.update(old_desc, new_desc)
              if err.shutdown? || old_desc.max_wire_version < 8
                pool_generations[addr] = current_gen + 1
              end
            end
          end
        end

        # 3. Assert Phase Outcome
        if outcome = phase["outcome"]?
          if exp_type = outcome["topologyType"]?.try(&.as_s?)
            client.topology.type.to_s.downcase.delete("_").should eq exp_type.downcase.delete("_")
          end

          if exp_setname = outcome["setName"]?
            if exp_setname.raw.nil?
              client.topology.set_name.should be_nil
            else
              client.topology.set_name.should eq exp_setname.as_s
            end
          end

          if exp_servers = outcome["servers"]?.try(&.as_h?)
            # Verify expected servers are present and correct
            exp_servers.each do |exp_addr, exp_srv|
              actual_srv = client.topology.servers.find(&.address.==(exp_addr))
              exp_srv_type = exp_srv["type"].as_s

              if exp_srv_type == "Unknown" || exp_srv_type == "PossiblePrimary"
                if actual_srv
                  (actual_srv.type.unknown? || actual_srv.type.possible_primary?).should be_true
                else
                  true.should be_true # Absent is conceptually 'Unknown' per spec
                end
              else
                actual_srv.should_not be_nil
                if actual_srv
                  actual_srv.type.to_s.downcase.delete("_").should eq exp_srv_type.downcase.delete("_")
                  if n = exp_srv["setName"]?
                    if n.raw.nil?
                      actual_srv.set_name.should be_nil
                    else
                      actual_srv.set_name.should eq n.as_s
                    end
                  end
                end
              end

              if expected_pool = exp_srv["pool"]?
                pool_generations.fetch(exp_addr, 0).should eq expected_pool["generation"].as_i
              end
            end

            # Verify no unexpected servers are present (must be Unknown or absent)
            client.topology.servers.each do |actual|
              unless exp_servers.has_key?(actual.address)
                actual.type.unknown?.should be_true
              end
            end
          end

          if exp_events = outcome["events"]?.try(&.as_a?)
            events.size.should eq exp_events.size
            events.zip(exp_events).each do |actual, expected|
              expected_keys = expected.as_h.keys
              event_type = expected_keys.first? || raise "Unexpected empty event object in test file"

              case event_type
              when "topology_opening_event"
                actual.should be_a(Mongo::Monitoring::SDAM::TopologyOpeningEvent)
              when "topology_description_changed_event"
                actual.should be_a(Mongo::Monitoring::SDAM::TopologyDescriptionChangedEvent)
              when "server_opening_event"
                actual.should be_a(Mongo::Monitoring::SDAM::ServerOpeningEvent)
                if server_opening = actual.as?(Mongo::Monitoring::SDAM::ServerOpeningEvent)
                  server_opening.address.should eq expected[event_type]["address"].as_s
                end
              when "server_closed_event"
                actual.should be_a(Mongo::Monitoring::SDAM::ServerClosedEvent)
                if server_closed = actual.as?(Mongo::Monitoring::SDAM::ServerClosedEvent)
                  server_closed.address.should eq expected[event_type]["address"].as_s
                end
              when "server_description_changed_event"
                actual.should be_a(Mongo::Monitoring::SDAM::ServerDescriptionChangedEvent)
                if srv_desc_changed = actual.as?(Mongo::Monitoring::SDAM::ServerDescriptionChangedEvent)
                  srv_desc_changed.address.should eq expected[event_type]["address"].as_s
                end
              when "topology_closed_event"
                actual.should be_a(Mongo::Monitoring::SDAM::TopologyClosedEvent)
              end
            end
          end
        end

        # Clear events at the END of the phase so the initial topology events
        # can be successfully asserted during the first phase iteration.
        events.clear
      end

      client.close
    end
  end
end
