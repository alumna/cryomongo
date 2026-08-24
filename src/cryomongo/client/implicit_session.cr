class Mongo::Client
  # One implicit ClientSession per fiber. Consecutive commands on the same
  # fiber reuse the same ServerSession. Dirty sessions are replaced on the
  # next command. Client#close returns them to the pool before endSessions.
  private def implicit_session_for_fiber : Session::ClientSession
    fiber = Fiber.current
    session = @fiber_sessions_lock.synchronize do
      prune_fiber_sessions
      existing = @fiber_sessions[fiber]?
      if existing && !existing.released?
        existing
      else
        created = Session::ClientSession.new(self, fiber_owned: true)
        @fiber_sessions[fiber] = created
        created
      end
    end
    session.recycle_dirty_server_session
    session
  end

  private def prune_fiber_sessions : Nil
    dead = [] of Fiber
    @fiber_sessions.each do |fiber, session|
      next unless fiber.dead?
      session.end
      dead << fiber
    end
    dead.each { |fiber| @fiber_sessions.delete(fiber) }
  end

  private def end_fiber_implicit_sessions : Nil
    @fiber_sessions_lock.synchronize do
      @fiber_sessions.each_value(&.end)
      @fiber_sessions.clear
    end
  end
end
