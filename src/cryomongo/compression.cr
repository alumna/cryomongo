require "compress/zlib"
require "snappy"
require "sync"
require "zstd/compress/context"
require "zstd/decompress/context"
require "./error"

# Wire compression (OP_COMPRESSED). Handshake lists compressors the driver can
# actually use. Unknown names are dropped with a warning. zlib is in the Crystal
# stdlib. snappy is pure Crystal. zstd uses libzstd.
module Mongo::Compression
  extend self

  enum Id : UInt8
    Noop   = 0
    Snappy = 1
    Zlib   = 2
    Zstd   = 3
  end

  # Handshake names this driver can compress and decompress.
  SUPPORTED = {"snappy", "zlib", "zstd", "noop"}

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

  @@zstd_lock = Sync::Mutex.new
  @@zstd_cctx : Zstd::Compress::Context? = nil
  @@zstd_dctx : Zstd::Decompress::Context? = nil
  @@zstd_dst = Bytes.empty

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
    when .snappy?
      output.write(Compress::Snappy.encode(input))
    when .zstd?
      @@zstd_lock.synchronize do
        ctx = zstd_cctx
        need = ctx.compress_bound(input.size)
        dst = @@zstd_dst
        if dst.size < need
          dst = Bytes.new(need)
          @@zstd_dst = dst
        end
        output.write(ctx.compress(input, dst))
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
    when .snappy?
      plain = Bytes.new(uncompressed_size)
      n = Compress::Snappy.decode(input, plain)
      unless n == uncompressed_size
        raise Mongo::Error.new("snappy decompressed #{n} bytes, expected #{uncompressed_size}")
      end
      plain
    when .zstd?
      plain = Bytes.new(uncompressed_size)
      @@zstd_lock.synchronize do
        got = zstd_dctx.decompress(input, plain)
        unless got.size == uncompressed_size
          raise Mongo::Error.new("zstd decompressed #{got.size} bytes, expected #{uncompressed_size}")
        end
      end
      plain
    when .noop?
      input
    else
      raise Mongo::Error.new("Cannot decompress #{name_of(id)}")
    end
  end

  private def zstd_cctx : Zstd::Compress::Context
    ctx = @@zstd_cctx
    return ctx if ctx
    ctx = Zstd::Compress::Context.new
    @@zstd_cctx = ctx
    ctx
  end

  private def zstd_dctx : Zstd::Decompress::Context
    ctx = @@zstd_dctx
    return ctx if ctx
    ctx = Zstd::Decompress::Context.new
    @@zstd_dctx = ctx
    ctx
  end
end
