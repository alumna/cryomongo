# Fill *slice* or raise IO::EOFError. execute_command treats that as a network
# error (retry, pool clear, RetryableWriteError). read_greedy does not raise
# on a short EOF, so this helper matches Crystal IO#read_fully.
module Mongo::Messages
  def self.read_exact(io : IO, slice : Bytes) : Nil
    n = io.read_greedy(slice)
    return if n == slice.size
    if n == 0
      raise IO::EOFError.new
    end
    raise IO::EOFError.new("read #{n} bytes out of #{slice.size}")
  end
end
