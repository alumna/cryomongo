require "./spec_helper"
require "./cmap/runner"
require "./sharding"

describe "CMAP cmap-format runner" do
  Spec.after_suite { Mongo::Cmap::Runner.close_admin_client }

  files = Dir.glob("spec/tests/cmap/**/*.json").sort
  files = Mongo::SpecSharding.filter(files)

  files.each do |file|
    it "executes: #{file}" do
      Mongo::Cmap::Runner.new(file).run
    rescue e : Mongo::Cmap::Skip
      pending! e.message || "skipped"
    rescue e : Mongo::Error::ServerSelection
      pending! "MongoDB is not reachable (#{e.message}). Run: sudo scripts/mongo-topology.sh standalone"
    end
  end
end
