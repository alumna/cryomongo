# DriverBench datasets. Official JSON/bin files are used when they exist under
# bench/data/. Otherwise documents are built in memory to the spec sizes.

module DriverBench
  module Datasets
    extend self

    DATA_DIR = File.expand_path("data", __DIR__)

    FLAT_FILE_SIZE   = 7_531_i64
    DEEP_FILE_SIZE   = 2_284_i64
    FULL_FILE_SIZE   = 5_734_i64
    TWEET_FILE_SIZE  = 1_622_i64
    SMALL_FILE_SIZE  = 275_i64
    LARGE_FILE_SIZE  = 2_731_089_i64
    GRIDFS_FILE_SIZE = 52_428_800_i64

    BSON_REPEAT = 10_000
    HELLO_BYTES = 130_000_i64

    def tweet : BSON
      if bytes = read_file?("tweet.json")
        return BSON.from_json(String.new(bytes))
      end
      BSON.build do |b|
        b["text"] = "x" * 80
        b["user"] = "bench"
        b["source"] = "web"
        b["retweet"] = false
        b["pad"] = "t" * 1400
      end
    end

    def small_doc : BSON
      if bytes = read_file?("small_doc.json")
        return BSON.from_json(String.new(bytes))
      end
      BSON.build do |b|
        b["a"] = 1
        b["b"] = "small"
        b["c"] = true
        b["d"] = "x" * 200
      end
    end

    def large_doc : BSON
      if bytes = read_file?("large_doc.json")
        return BSON.from_json(String.new(bytes))
      end
      BSON.build do |b|
        b["n"] = 1
        b["payload"] = "L" * (LARGE_FILE_SIZE - 40).to_i
      end
    end

    def gridfs_bytes : Bytes
      if bytes = read_file?("gridfs_large.bin")
        return bytes
      end
      n = 1_048_576
      n = 52_428_800 if ENV["BENCH_FULL"]?
      Bytes.new(n) { |i| (i &* 31 & 0xff).to_u8 }
    end

    def tweet_size : Int64
      file_size("tweet.json", TWEET_FILE_SIZE)
    end

    def small_size : Int64
      file_size("small_doc.json", SMALL_FILE_SIZE)
    end

    def large_size : Int64
      file_size("large_doc.json", LARGE_FILE_SIZE)
    end

    def flat_source : Hash(String, BSON::Value)
      doc = {} of String => BSON::Value
      doc["_id"] = BSON::ObjectId.new
      24.times do |i|
        doc["s%07d" % i] = "x" * 80
        doc["i%07d" % i] = i
        doc["l%07d" % i] = i.to_i64
        doc["d%07d" % i] = i.to_f64
        doc["b%07d" % i] = i.even?
      end
      doc
    end

    def deep_source(depth : Int32 = 6) : Hash(String, BSON::Value)
      if depth <= 0
        h = {} of String => BSON::Value
        h["leftValue"] = "abcdefgh"
        h["rightValue"] = "ijklmnop"
        return h
      end
      h = {} of String => BSON::Value
      h["left"] = BSON.new(deep_source(depth - 1))
      h["right"] = BSON.new(deep_source(depth - 1))
      h
    end

    def full_source : Hash(String, BSON::Value)
      doc = {} of String => BSON::Value
      doc["_id"] = BSON::ObjectId.new
      6.times do |i|
        doc["s%07d" % i] = "x" * 80
        doc["d%07d" % i] = i.to_f64
        doc["l%07d" % i] = i.to_i64
        doc["i%07d" % i] = i
        doc["b%07d" % i] = i.even?
        doc["n%07d" % i] = BSON::MinKey.new
        doc["x%07d" % i] = BSON::MaxKey.new
        doc["a%07d" % i] = BSON.new([i, i + 1])
        doc["y%07d" % i] = Bytes.new(16) { |j| (i + j).to_u8 }
        doc["t%07d" % i] = Time.utc(2020, 1, 1, 0, 0, i)
        doc["r%07d" % i] = BSON::Regex.new("abc", "i")
        doc["j%07d" % i] = BSON::Code.new("function(){}")
        doc["u%07d" % i] = BSON::Timestamp.new(i.to_u32, 1_u32)
      end
      doc
    end

    private def read_file?(name : String) : Bytes?
      path = File.join(DATA_DIR, name)
      return nil unless File.file?(path)
      File.read(path).to_slice
    end

    private def file_size(name : String, fallback : Int64) : Int64
      path = File.join(DATA_DIR, name)
      File.file?(path) ? File.size(path).to_i64 : fallback
    end
  end
end
