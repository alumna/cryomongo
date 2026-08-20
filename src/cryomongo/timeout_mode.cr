# How timeoutMS applies to a cursor.
#
# CursorLifetime: one deadline from the first command through the last getMore.
# Iteration: each next/getMore gets a fresh timeoutMS. Tailable and change streams use this.
enum Mongo::TimeoutMode
  CursorLifetime
  Iteration
end

module Mongo
  # maxAwaitTimeMS must be less than a non-zero timeoutMS (tailable awaitData / change streams).
  def self.check_max_await_vs_timeout(max_await_time_ms : Int64?, timeout_ms : Int64?) : Nil
    return unless max_await_time_ms && timeout_ms && timeout_ms > 0
    if max_await_time_ms >= timeout_ms
      raise Mongo::Error.new("maxAwaitTimeMS must be less than timeoutMS")
    end
  end
end
