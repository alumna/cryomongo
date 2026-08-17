module Mongo::SpecSharding
  extend self

  # Optional split of UTF JSON files for CI.
  # Local runs and the default GitHub Actions job leave CI_SHARD unset, so
  # every file runs. Set CI_SHARD="0/5" … "4/5" only if the suite grows
  # and one job is too slow again.
  #
  # The split is greedy bin-packing by file size (Longest Processing Time).
  def filter(files : Array(String)) : Array(String)
    if split = ENV["CI_SHARD"]?
      part, total = split.split('/').map(&.to_i)

      # 1. Compute size once per file, then sort by it descending (LPT heuristic).
      # This avoids mutating the original `files` array and halves `stat` syscalls.
      sized_files = files.map { |file| {file, File.size(file).to_i64} }
      sized_files.sort_by! { |_, size| -size }

      # 2. Track the accumulated "cost" (bytes) and assigned files for each shard
      shard_costs = Array(Int64).new(total, 0_i64)
      shard_files = Array(Array(String)).new(total) { [] of String }

      # 3. Greedy bin-packing: assign each file to the currently "lightest" shard
      sized_files.each do |file, cost|
        min_shard = 0
        min_cost = shard_costs[0]

        shard_costs.each_with_index do |current_cost, index|
          if current_cost < min_cost
            min_cost = current_cost
            min_shard = index
          end
        end

        shard_files[min_shard] << file
        shard_costs[min_shard] += cost
      end

      # Return only the files assigned to the current CI runner
      shard_files[part]
    else
      # If CI_SHARD is not set (e.g., running locally), return all files
      files
    end
  end
end
