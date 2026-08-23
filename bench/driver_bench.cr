# Official MongoDB Driver Performance Benchmark (DriverBench).
#
# BSON tasks always run. Live tasks need MONGODB_URI and a reachable server.
# BENCH_FULL=1 uses the spec time bounds and the large GridFS file.
#
#   crystal run bench/driver_bench.cr
#   shards build --release driver_bench && bin/driver_bench
#   MONGODB_URI=mongodb://localhost:27017 crystal run bench/driver_bench.cr
#   BENCH_FULL=1 MONGODB_URI=mongodb://localhost:27017 shards build --release driver_bench && bin/driver_bench
#
# Each run writes bench/results/<utc>-<mode>-<topology>.json unless BENCH_SAVE=0.
#
# Score is MB/s from the median iteration (SI megabyte = 1,000,000 bytes).
# Client bulkWrite is implemented (`Client#bulk_write`). This bench still uses collection writes.
# Official 500k LDJSON parallel files are skipped (too large to vendor).

require "wait_group"
require "../src/cryomongo"
require "./timing"
require "./datasets"
require "./report"

module DriverBench
  extend self

  def run : Nil
    recorded_at = Time.utc
    live_meta = Report::LiveMeta.new
    bson = [] of Timing::Result
    live = [] of Timing::Result
    composites = {} of String => Float64
    elapsed = Time.measure do
      puts "DriverBench  min_iters=#{Timing::MIN_ITERS}  task_s=#{Timing::TASK_SECONDS}  max_s=#{Timing::MAX_SECONDS}"
      bson = run_bson
      live = run_live(live_meta)
      composites = Report.composites(bson, live)
      print_composites(composites)
    end
    Report.save(
      recorded_at: recorded_at,
      elapsed_s: elapsed.total_seconds,
      bson: bson,
      live: live,
      composites: composites,
      live_meta: live_meta
    )
  end

  private def run_bson : Array(Timing::Result)
    puts ""
    puts "== BSON =="
    flat_src = Datasets.flat_source
    flat_bytes = BSON.new(flat_src).data
    deep_src = Datasets.deep_source
    deep_bytes = BSON.new(deep_src).data
    full_src = Datasets.full_source
    full_bytes = BSON.new(full_src).data
    n = Datasets::BSON_REPEAT

    results = [] of Timing::Result
    # Encode from a Hash. Decode walks fields into a Hash (spec native document).
    # Timing.keep stops --release from dropping the loop.
    results << Timing.run("flat bson encode", Datasets::FLAT_FILE_SIZE * n) do
      n.times { Timing.keep(BSON.new(flat_src).size.to_i64) }
    end
    results << Timing.run("flat bson decode", Datasets::FLAT_FILE_SIZE * n) do
      n.times { Timing.keep(BSON.new(flat_bytes).to_h.size.to_i64) }
    end
    results << Timing.run("deep bson encode", Datasets::DEEP_FILE_SIZE * n) do
      n.times { Timing.keep(BSON.new(deep_src).size.to_i64) }
    end
    results << Timing.run("deep bson decode", Datasets::DEEP_FILE_SIZE * n) do
      n.times { Timing.keep(BSON.new(deep_bytes).to_h.size.to_i64) }
    end
    results << Timing.run("full bson encode", Datasets::FULL_FILE_SIZE * n) do
      n.times { Timing.keep(BSON.new(full_src).size.to_i64) }
    end
    results << Timing.run("full bson decode", Datasets::FULL_FILE_SIZE * n) do
      n.times { Timing.keep(BSON.new(full_bytes).to_h.size.to_i64) }
    end
    puts "BSONBench: #{Timing.mean(results.map(&.mb_s)).round(2)} MB/s"
    results
  end

  private def run_live(live_meta : Report::LiveMeta) : Array(Timing::Result)
    uri = ENV["MONGODB_URI"]?
    unless uri && !uri.empty?
      puts ""
      puts "skip live tasks: set MONGODB_URI to a MongoDB 8.0 URI"
      return [] of Timing::Result
    end

    live_meta.uri_redacted = Report.redact_uri(uri)
    live_meta.topology = Report.topology_from_uri(uri)

    client = Mongo::Client.new(append_query(uri, "serverSelectionTimeoutMS=5000"))
    begin
      client.command(Mongo::Commands::Ping)
    rescue error : Mongo::Error::ServerSelection
      puts "skip live tasks: #{error.message}"
      client.close
      return [] of Timing::Result
    end
    begin
      info = client.command(Mongo::Commands::BuildInfo)
      live_meta.version = info.try(&.version)
    rescue
    end

    puts ""
    puts "== Single-doc / Multi-doc =="
    results = [] of Timing::Result
    begin
      db = client["perftest"]
      drop_db(client)

      results << Timing.run("run command hello", Datasets::HELLO_BYTES) do
        Datasets::BSON_REPEAT.times do
          db.client["admin"].run_command({hello: true})
        end
      end

      tweet = Datasets.tweet
      tweet_n = Datasets::BSON_REPEAT
      tweet_bytes = Datasets.tweet_size
      coll = db["corpus"]
      drop_corpus(db)
      tweet_n.times do |i|
        doc = BSON.new({_id: i + 1})
        doc.append(tweet)
        coll.insert_one(doc)
      end

      results << Timing.run("find one by id", tweet_bytes * tweet_n) do
        tweet_n.times { |i| coll.find_one({_id: i + 1}) }
      end

      small = Datasets.small_doc
      small_bytes = Datasets.small_size
      small_n = Datasets::BSON_REPEAT
      drop_before = -> { drop_corpus(db) }

      results << Timing.run("small insertOne", small_bytes * small_n, drop_before) do
        c = db["corpus"]
        small_n.times { c.insert_one(BSON.new(small.data)) }
      end

      large = Datasets.large_doc
      large_bytes = Datasets.large_size
      large_n = 10
      results << Timing.run("large insertOne", large_bytes * large_n, drop_before) do
        c = db["corpus"]
        large_n.times { c.insert_one(BSON.new(large.data)) }
      end

      drop_corpus(db)
      tweet_n.times { coll.insert_one(BSON.new(tweet.data)) }
      results << Timing.run("find many", tweet_bytes * tweet_n) do
        db["corpus"].find.each { |_| }
      end

      results << Timing.run("small insertMany", small_bytes * small_n, drop_before) do
        docs = Array(BSON).new(small_n) { BSON.new(small.data) }
        db["corpus"].insert_many(docs)
      end

      results << Timing.run("large insertMany", large_bytes * large_n, drop_before) do
        docs = Array(BSON).new(large_n) { BSON.new(large.data) }
        db["corpus"].insert_many(docs)
      end

      small_models = Array(Mongo::Bulk::WriteModel).new(small_n) { Mongo::Bulk::InsertOne.new(BSON.new(small.data)) }
      results << Timing.run("small collection bulkWrite", small_bytes * small_n, drop_before) do
        db["corpus"].bulk_write(small_models, ordered: true)
      end

      large_models = Array(Mongo::Bulk::WriteModel).new(large_n) { Mongo::Bulk::InsertOne.new(BSON.new(large.data)) }
      results << Timing.run("large collection bulkWrite", large_bytes * large_n, drop_before) do
        db["corpus"].bulk_write(large_models, ordered: true)
      end

      mixed_n = ENV["BENCH_FULL"]? ? small_n : 200
      mixed = Array(Mongo::Bulk::WriteModel).new
      mixed_n.times do
        mixed << Mongo::Bulk::InsertOne.new(BSON.new(small.data))
        mixed << Mongo::Bulk::ReplaceOne.new(BSON.new, BSON.new(small.data))
        mixed << Mongo::Bulk::DeleteOne.new(BSON.new)
      end
      results << Timing.run("small collection bulkWrite mixed", small_bytes * mixed_n.to_i64 * 2, drop_before) do
        db["corpus"].bulk_write(mixed, ordered: true)
      end

      grid = Datasets.gridfs_bytes
      bucket = db.grid_fs
      grid_before = -> {
        drop_gridfs(db)
        bucket.upload_from_stream("init", IO::Memory.new(Bytes[1]))
        nil
      }
      results << Timing.run("gridfs upload", grid.size.to_i64, grid_before) do
        bucket.upload_from_stream("gridfstest", IO::Memory.new(grid))
      end

      drop_gridfs(db)
      id = bucket.upload_from_stream("gridfstest", IO::Memory.new(grid))
      results << Timing.run("gridfs download", grid.size.to_i64) do
        bucket.download_to_stream(id, IO::Memory.new)
      end

      fiber_n = ENV["BENCH_FULL"]? ? 32 : 8
      docs_each = ENV["BENCH_FULL"]? ? 1_000 : 250
      parallel_bytes = small_bytes * fiber_n * docs_each
      results << Timing.run("parallel small insertMany", parallel_bytes, drop_before) do
        wg = WaitGroup.new(fiber_n)
        fiber_n.times do |i|
          spawn do
            begin
              docs = Array(BSON).new(docs_each) { BSON.new(small.data) }
              db["corpus_#{i}"].insert_many(docs, ordered: false)
            ensure
              wg.done
            end
          end
        end
        wg.wait
      end
    ensure
      drop_db(client)
      client.close
    end
    results
  end

  private def print_composites(composites : Hash(String, Float64)) : Nil
    puts ""
    puts "== Composite =="
    %w[BSONBench SingleBench MultiBench ReadBench WriteBench DriverBench].each do |name|
      if value = composites[name]?
        puts "#{name}: #{value.round(2)} MB/s"
      end
    end
  end

  private def drop_db(client : Mongo::Client) : Nil
    client["perftest"].command(Mongo::Commands::DropDatabase) rescue nil
  end

  private def drop_gridfs(db : Mongo::Database) : Nil
    db.command(Mongo::Commands::Drop, name: "fs.files") rescue nil
    db.command(Mongo::Commands::Drop, name: "fs.chunks") rescue nil
  end

  private def drop_corpus(db : Mongo::Database) : Nil
    db.command(Mongo::Commands::Drop, name: "corpus") rescue nil
    db.command(Mongo::Commands::Create, name: "corpus") rescue nil
  end

  private def append_query(uri : String, options : String) : String
    if uri.includes?('?')
      "#{uri}&#{options}"
    elsif uri.ends_with?('/')
      "#{uri}?#{options}"
    else
      "#{uri}/?#{options}"
    end
  end
end

DriverBench.run
