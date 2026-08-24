# Shared SDAM rules for application errors. Production and the legacy JSON
# runner use the same decide() so handshake / generation policy is not forked.
module Mongo::SDAM::ApplicationError
  extend self

  enum Kind
    Network
    Timeout
    Command
  end

  enum Phase
    BeforeHandshake
    AfterHandshake
  end

  enum Action
    Ignore
    MarkUnknown
    MarkUnknownAndClearPool
  end

  def decide(
    kind : Kind,
    phase : Phase,
    *,
    stale : Bool,
    state_change : Bool = false,
    shutdown : Bool = false,
    max_wire_version : Int32 = 0,
  ) : Action
    if stale
      return Action::Ignore
    end

    case kind
    when .timeout?
      Action::Ignore
    when .network?
      phase.before_handshake? ? Action::Ignore : Action::MarkUnknownAndClearPool
    when .command?
      if !state_change
        Action::Ignore
      elsif shutdown || max_wire_version < 8
        Action::MarkUnknownAndClearPool
      else
        Action::MarkUnknown
      end
    else
      Action::Ignore
    end
  end
end
