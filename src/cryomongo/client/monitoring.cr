class Mongo::Client
  # Subscribe to monitoring command events.
  #
  # ```
  # client = Mongo::Client.new
  #
  # client.subscribe_commands { |event|
  #   case event
  #   when Mongo::Monitoring::Commands::CommandStartedEvent
  #     Log.info { "COMMAND.#{event.command_name} #{event.address} STARTED: #{event.command.to_json}" }
  #   when Mongo::Monitoring::Commands::CommandSucceededEvent
  #     Log.info { "COMMAND.#{event.command_name} #{event.address} COMPLETED: #{event.reply.to_json} (#{event.duration}s)" }
  #   when Mongo::Monitoring::Commands::CommandFailedEvent
  #     Log.info { "COMMAND.#{event.command_name} #{event.address} FAILED: #{event.failure.inspect} (#{event.duration}s)" }
  #   end
  # }
  # ```
  def subscribe_commands(&callback : Monitoring::Commands::Event -> Nil) : Monitoring::Commands::Event -> Nil
    @commands_observable.subscribe(&callback)
  end

  # Ends the subscription for command events.
  #
  # ```
  # client = Mongo::Client.new
  #
  # subscription = client.subscribe_commands { |event|
  #   puts event
  # }
  #
  # client.unsubscribe_commands(subscription)
  # ```
  def unsubscribe_commands(callback : Monitoring::Commands::Event -> Nil) : Nil
    @commands_observable.unsubscribe(callback)
  end

  private def start_monitoring
    @monitors.each { spawn &.scan }
  end

  protected def add_monitor(server_description : SDAM::ServerDescription, *, start_monitoring = true)
    monitor = SDAM::Monitor.new(self, server_description, @credentials, @options.heartbeat_frequency || 10.seconds)
    @monitors << monitor
    if start_monitoring
      spawn monitor.scan
    end
  end

  protected def stop_monitoring(server_description : SDAM::ServerDescription)
    @@topology_lock.synchronize {
      @monitors.reject!(server_description)
    }
  end
end
