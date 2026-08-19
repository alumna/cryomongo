require "./spec_helper"

private def number_ms(value : JSON::Any) : Float64
  value.as_f? || value.as_i64.to_f
end

describe "RTT EWMA spec tests" do
  files = Dir.glob("spec/tests/legacy/server-selection/rtt/*.json").sort

  files.each do |file|
    it "computes average RTT in #{file}" do
      json = JSON.parse(File.read(file))
      old = if (raw = json["avg_rtt_ms"].raw).is_a?(String) && raw.as(String).upcase == "NULL"
              nil
            else
              number_ms(json["avg_rtt_ms"]).milliseconds
            end
      new_rtt = number_ms(json["new_rtt_ms"]).milliseconds
      expected = number_ms(json["new_avg_rtt"])

      got = Mongo::Connection.average_round_trip_time(new_rtt, old)
      got.total_milliseconds.should eq expected
    end
  end
end
