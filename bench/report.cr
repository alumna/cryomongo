# Writes one JSON file per DriverBench run under bench/results/.
# Also updates bench/results/index.json so later runs can be listed.
#
#   BENCH_SAVE=0              skip writing
#   BENCH_RESULTS_DIR=path    override the folder (default: bench/results)

require "json"
require "./timing"
require "./datasets"

module DriverBench
  module Report
    extend self

    SCHEMA = 1

    ROOT = File.expand_path("..", __DIR__)

    SINGLE_NAMES = {"find one by id", "small insertOne", "large insertOne"}
    MULTI_NAMES  = {
      "find many", "small insertMany", "large insertMany",
      "small collection bulkWrite", "large collection bulkWrite",
      "small collection bulkWrite mixed",
      "small client bulkWrite", "large client bulkWrite",
      "small client bulkWrite mixed",
      "gridfs upload", "gridfs download",
    }
    READ_NAMES = {"find one by id", "find many", "gridfs download"}
    # Spec WriteBench. Parallel insertMany is a local extra task and stays out.
    WRITE_NAMES = {
      "small insertOne", "large insertOne", "small insertMany", "large insertMany",
      "small collection bulkWrite", "large collection bulkWrite",
      "small collection bulkWrite mixed",
      "small client bulkWrite", "large client bulkWrite",
      "small client bulkWrite mixed",
      "gridfs upload",
    }

    class LiveMeta
      property version : String?
      property topology : String
      property uri_redacted : String?

      def initialize
        @topology = "none"
      end
    end

    class TaskRow
      include JSON::Serializable

      getter name : String
      getter group : String
      getter median_ms : Float64
      getter mb_s : Float64
      getter n : Int32
      getter bytes : Int64

      def initialize(@name, @group, @median_ms, @mb_s, @n, @bytes)
      end
    end

    class HostInfo
      include JSON::Serializable

      getter os : String
      getter cpu : String
      getter cpus : Int32
      getter ram_kib : Int64?
      getter crystal : String
      getter release : Bool
      getter git_commit : String?
      getter git_branch : String?

      def initialize(@os, @cpu, @cpus, @ram_kib, @crystal, @release, @git_commit, @git_branch)
      end
    end

    class MongoInfo
      include JSON::Serializable

      getter version : String?
      getter topology : String
      getter uri : String?
      getter same_machine : Bool

      def initialize(@version, @topology, @uri, @same_machine)
      end
    end

    class DatasetInfo
      include JSON::Serializable

      getter source : String
      getter gridfs_bytes : Int64
      getter mixed_n : Int32
      getter official_files : Hash(String, Bool)

      def initialize(@source, @gridfs_bytes, @mixed_n, @official_files)
      end
    end

    class BoundsInfo
      include JSON::Serializable

      getter min_iters : Int32
      getter task_seconds : Float64
      getter max_seconds : Float64

      def initialize(@min_iters, @task_seconds, @max_seconds)
      end
    end

    class RunDocument
      include JSON::Serializable

      getter schema : Int32
      getter recorded_at : String
      getter elapsed_s : Float64
      getter mode : String
      getter host : HostInfo
      getter mongodb : MongoInfo?
      getter bounds : BoundsInfo
      getter datasets : DatasetInfo
      getter tasks : Array(TaskRow)
      getter composites : Hash(String, Float64)
      getter notes : Array(String)

      def initialize(
        @schema, @recorded_at, @elapsed_s, @mode, @host, @mongodb,
        @bounds, @datasets, @tasks, @composites, @notes
      )
      end
    end

    class IndexEntry
      include JSON::Serializable

      getter file : String
      getter recorded_at : String
      getter mode : String
      getter topology : String
      getter release : Bool
      getter composites : Hash(String, Float64)

      def initialize(@file, @recorded_at, @mode, @topology, @release, @composites)
      end
    end

    class IndexFile
      include JSON::Serializable

      getter schema : Int32
      getter runs : Array(IndexEntry)

      def initialize(@schema, @runs)
      end
    end

    def results_dir : String
      ENV["BENCH_RESULTS_DIR"]? || File.expand_path("results", __DIR__)
    end

    def mode : String
      ENV["BENCH_FULL"]? ? "full" : "short"
    end

    def redact_uri(uri : String) : String
      uri.gsub(%r{://([^/@]+):([^/@]+)@}, "://***:***@")
    end

    def topology_from_uri(uri : String) : String
      return "load-balanced" if uri.includes?("loadBalanced=true")
      return "replica-set" if uri.includes?("replicaSet=")
      rest = uri.sub(%r{\Amongodb(\+srv)?://}i, "")
      rest = rest.sub(%r{\A[^/]*@}, "")
      hosts = rest.split('?', 2)[0].split('/')[0]
      return "multi-host" if hosts.includes?(',')
      "standalone"
    end

    def same_machine?(uri : String) : Bool
      hostpart = uri.sub(%r{\Amongodb(\+srv)?://}i, "")
      hostpart = hostpart.sub(%r{\A[^/]*@}, "")
      hostpart = hostpart.split('?', 2)[0].split('/')[0].downcase
      hostpart.includes?("localhost") || hostpart.includes?("127.0.0.1") || hostpart.includes?("[::1]")
    end

    def group_for(name : String) : String
      case name
      when "flat bson encode", "flat bson decode",
           "deep bson encode", "deep bson decode",
           "full bson encode", "full bson decode"
        "bson"
      when "run command hello", "find one by id", "small insertOne", "large insertOne"
        "single"
      when "find many", "small insertMany", "large insertMany",
           "small collection bulkWrite", "large collection bulkWrite",
           "small collection bulkWrite mixed",
           "small client bulkWrite", "large client bulkWrite",
           "small client bulkWrite mixed",
           "gridfs upload", "gridfs download"
        "multi"
      else
        "extra"
      end
    end

    def composites(bson : Array(Timing::Result), live : Array(Timing::Result)) : Hash(String, Float64)
      scores = {} of String => Float64
      unless bson.empty?
        scores["BSONBench"] = Timing.mean(bson.map(&.mb_s))
      end
      return scores if live.empty?

      by = {} of String => Float64
      live.each { |r| by[r.name] = r.mb_s }

      single = mean_of(by, SINGLE_NAMES)
      multi = mean_of(by, MULTI_NAMES)
      read = mean_of(by, READ_NAMES)
      write = mean_of(by, WRITE_NAMES)
      scores["SingleBench"] = single if single > 0
      scores["MultiBench"] = multi if multi > 0
      scores["ReadBench"] = read if read > 0
      scores["WriteBench"] = write if write > 0
      if read > 0 && write > 0
        scores["DriverBench"] = (read + write) / 2.0
      end
      scores
    end

    def save(
      recorded_at : Time,
      elapsed_s : Float64,
      bson : Array(Timing::Result),
      live : Array(Timing::Result),
      composites : Hash(String, Float64),
      live_meta : LiveMeta
    ) : String?
      return nil if ENV["BENCH_SAVE"]? == "0"

      dir = results_dir
      Dir.mkdir_p(dir)

      stamp = recorded_at.to_utc.to_s("%Y-%m-%dT%H%M%SZ")
      topo = live.empty? ? "bson-only" : live_meta.topology
      file_name = "#{stamp}-#{mode}-#{topo}.json"
      path = File.join(dir, file_name)

      tasks = (bson + live).map do |r|
        TaskRow.new(
          r.name,
          group_for(r.name),
          (r.median_s * 1000).round(2),
          r.mb_s.round(2),
          r.n,
          r.bytes
        )
      end

      official = {} of String => Bool
      %w[tweet.json small_doc.json large_doc.json gridfs_large.bin flat_bson.json deep_bson.json full_bson.json].each do |name|
        official[name] = File.file?(File.join(Datasets::DATA_DIR, name))
      end
      any_official = official.values.any?
      mixed_n = ENV["BENCH_FULL"]? ? Datasets::BSON_REPEAT : 200
      grid_n = Datasets.gridfs_bytes.size.to_i64

      notes = [] of String
      notes << "Generated in-memory documents. Official files were not in bench/data/." unless any_official
      notes << "GridFS file is #{grid_n} bytes (spec size is #{Datasets::GRIDFS_FILE_SIZE})." unless grid_n == Datasets::GRIDFS_FILE_SIZE
      notes << "Mixed collection and client bulkWrite used #{mixed_n} documents (spec size is #{Datasets::BSON_REPEAT})." unless mixed_n == Datasets::BSON_REPEAT
      notes << "BSON decode walks fields with to_h (native Hash). Encode keeps the byte size so --release cannot drop the loop."
      notes << "Parallel small insertMany is a local extra task. It is not in WriteBench or DriverBench."
      has_coll = live.any? { |r| r.name == "small collection bulkWrite" }
      has_client = live.any? { |r| r.name == "small client bulkWrite" }
      if has_coll && !has_client
        notes << "Client bulkWrite tasks were skipped (need MongoDB 8.0, wire version 25)."
      end
      if has_client
        notes << "Client bulkWrite insert and mixed tasks are in MultiBench, WriteBench, and DriverBench."
      end
      notes << "Crystal default build (not --release)." unless release_build?

      mongo = if live.empty?
                nil
              else
                uri = live_meta.uri_redacted
                MongoInfo.new(
                  live_meta.version,
                  live_meta.topology,
                  uri,
                  uri ? same_machine?(uri) : false
                )
              end

      doc = RunDocument.new(
        SCHEMA,
        recorded_at.to_utc.to_rfc3339,
        elapsed_s.round(2),
        mode,
        host_info,
        mongo,
        BoundsInfo.new(Timing::MIN_ITERS, Timing::TASK_SECONDS, Timing::MAX_SECONDS),
        DatasetInfo.new(any_official ? "official-or-mixed" : "generated", grid_n, mixed_n, official),
        tasks,
        round_composites(composites),
        notes
      )

      File.write(path, doc.to_pretty_json + "\n")
      update_index(dir, file_name, doc)
      puts ""
      puts "saved #{path}"
      path
    end

    def release_build? : Bool
      {{ flag?(:release) }}
    end

    private def round_composites(values : Hash(String, Float64)) : Hash(String, Float64)
      rounded = {} of String => Float64
      values.each { |k, v| rounded[k] = v.round(2) }
      rounded
    end

    private def mean_of(by : Hash(String, Float64), names : Enumerable(String)) : Float64
      vals = [] of Float64
      names.each do |n|
        if v = by[n]?
          vals << v
        end
      end
      Timing.mean(vals)
    end

    private def host_info : HostInfo
      HostInfo.new(
        uname_s,
        cpu_model,
        System.cpu_count.to_i,
        ram_kib,
        Crystal::VERSION,
        release_build?,
        git("rev-parse", "--short", "HEAD"),
        git("branch", "--show-current")
      )
    end

    private def uname_s : String
      {% if flag?(:linux) && flag?(:x86_64) %}
        "linux x86_64"
      {% elsif flag?(:linux) %}
        "linux"
      {% elsif flag?(:darwin) %}
        "darwin"
      {% else %}
        "unknown"
      {% end %}
    end

    private def cpu_model : String
      path = "/proc/cpuinfo"
      return "unknown" unless File.file?(path)
      File.each_line(path) do |line|
        if line.starts_with?("model name")
          parts = line.split(':', 2)
          return parts.size == 2 ? parts[1].strip : "unknown"
        end
      end
      "unknown"
    end

    private def ram_kib : Int64?
      path = "/proc/meminfo"
      return nil unless File.file?(path)
      File.each_line(path) do |line|
        next unless line.starts_with?("MemTotal:")
        return line.split[1].to_i64?
      end
      nil
    end

    private def git(*args : String) : String?
      output = IO::Memory.new
      status = Process.run("git", args.to_a, output: output, error: Process::Redirect::Close, chdir: ROOT)
      return nil unless status.success?
      text = output.to_s.strip
      text.empty? ? nil : text
    rescue
      nil
    end

    private def update_index(dir : String, file_name : String, doc : RunDocument) : Nil
      path = File.join(dir, "index.json")
      runs = [] of IndexEntry
      if File.file?(path)
        begin
          runs = IndexFile.from_json(File.read(path)).runs
        rescue
          runs = [] of IndexEntry
        end
      end
      topo = doc.mongodb.try(&.topology) || "bson-only"
      entry = IndexEntry.new(file_name, doc.recorded_at, doc.mode, topo, doc.host.release, doc.composites)
      runs.reject! { |r| r.file == file_name }
      runs << entry
      runs.sort_by! &.recorded_at
      File.write(path, IndexFile.new(SCHEMA, runs).to_pretty_json + "\n")
    end
  end
end
