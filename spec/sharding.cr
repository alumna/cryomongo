module Mongo::SpecSharding
  extend self

  # Filters an array of file paths based on the CI_SHARD environment variable
  # using a greedy cost-aware bin-packing algorithm (Longest Processing Time first).
  def filter(files : Array(String)) : Array(String)
    if split = ENV["CI_SHARD"]?
      part, total = split.split('/').map(&.to_i)

      # 1. Sort files by size, descending (Longest Processing Time first heuristic)
      files.sort_by! { |file| -File.size(file) }

      # 2. Track the accumulated "cost" (bytes) and assigned files for each shard
      shard_costs = Array(Int64).new(total, 0_i64)
      shard_files = Array(Array(String)).new(total) { [] of String }

      # 3. Greedy bin-packing: assign each file to the currently "lightest" shard
      files.each do |file|
        cost = File.size(file).to_i64

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
