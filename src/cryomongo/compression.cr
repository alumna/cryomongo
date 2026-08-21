require "compress/zlib"
require "./error"

# Wire compression (OP_COMPRESSED). Handshake lists compressors the driver can
# actually use. Unknown names are dropped with a warning. zlib is in the Crystal
# stdlib. snappy and zstd are not wired yet.
module Mongo::Compression
  extend self

  enum Id : UInt8
    Noop   = 0
    Snappy = 1
    Zlib   = 2
    Zstd   = 3
  end

  # Handshake names this driver can compress and decompress.
  SUPPORTED = {"zlib", "noop"}

  # Names the URI parser accepts. Others are unknown.
  KNOWN = {"snappy", "zlib", "zstd", "noop"}

  # Commands that must stay uncompressed (auth and handshake).
  FORBIDDEN = Set{
    "hello",
    "ismaster",
    "saslstart",
    "saslcontinue",
    "getnonce",
    "authenticate",
    "createuser",
    "updateuser",
    "copydbsaslstart",
    "copydbgetnonce",
    "copydb",
  }

  MAX_UNCOMPRESSED = 48_000_000

  # Split a URI compressors value. Keep the original order. Drop names this
  # driver cannot use. *warn* logs once at URI parse time.
  def parse_names(raw : String?, *, warn : Bool = false) : Array(String)
    return [] of String unless raw
    names = [] of String
    raw.split(',') do |part|
      name = part.strip
      next if name.empty?
      down = name.downcase
      unless KNOWN.includes?(down) && SUPPORTED.includes?(down)
        Mongo::Log.warn { "Unsupported compressor: '#{name}'" } if warn
        next
      end
      names << down unless names.includes?(down)
    end
    names
  end

  def forbidden?(command_name : String) : Bool
    FORBIDDEN.includes?(command_name.downcase)
  end

  # First name in the client list that the server also sent.
  def negotiate(client : Array(String), server : Array(String)?) : Id?
    return nil if client.empty?
    return nil unless server
    client.each do |name|
      matched = server.any? { |item| item.downcase == name }
      next unless matched
      return id_from_name(name)
    end
    nil
  end

  def id_from_name(name : String) : Id
    case name.downcase
    when "zlib"
      Id::Zlib
    when "noop"
      Id::Noop
    when "snappy"
      Id::Snappy
    when "zstd"
      Id::Zstd
    else
      raise Mongo::Error.new("Unknown compressor: #{name}")
    end
  end

  def name_of(id : Id) : String
    case id
    when .zlib?
      "zlib"
    when .noop?
      "noop"
    when .snappy?
      "snappy"
    when .zstd?
      "zstd"
    else
      "unknown"
    end
  end

  def deflate(id : Id, input : Bytes, output : IO, zlib_level : Int32) : Nil
    case id
    when .zlib?
      Compress::Zlib::Writer.open(output, level: zlib_level) do |writer|
        writer.write(input) unless input.empty?
      end
    when .noop?
      output.write(input)
    else
      raise Mongo::Error.new("Cannot compress with #{name_of(id)}")
    end
  end

  def inflate(compressor_id : UInt8, input : Bytes, uncompressed_size : Int32) : Bytes
    id = Id.from_value?(compressor_id)
    raise Mongo::Error.new("Unknown compressor id: #{compressor_id}") unless id
    inflate(id, input, uncompressed_size)
  end

  def inflate(id : Id, input : Bytes, uncompressed_size : Int32) : Bytes
    if uncompressed_size < 0 || uncompressed_size > MAX_UNCOMPRESSED
      raise Mongo::Error.new("Invalid uncompressed OP_COMPRESSED size: #{uncompressed_size}")
    end
    case id
    when .zlib?
      plain = Bytes.new(uncompressed_size)
      Compress::Zlib::Reader.open(IO::Memory.new(input, writable: false)) do |reader|
        n = reader.read_greedy(plain)
        unless n == uncompressed_size
          raise Mongo::Error.new("zlib decompressed #{n} bytes, expected #{uncompressed_size}")
        end
      end
      plain
    when .noop?
      input
    else
      raise Mongo::Error.new("Cannot decompress #{name_of(id)}")
    end
  end
end
