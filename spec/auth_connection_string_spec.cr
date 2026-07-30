require "./spec_helper"

describe "Auth Connection String (Legacy)" do
  file = "spec/tests/legacy/auth/connection-string.json"

  it "passes connection string legacy tests" do
    next unless File.exists?(file)

    json_data = File.read(file)
    test_suite = JSON.parse(json_data)

    test_suite["tests"].as_a.each do |test|
      uri_string = test["uri"].as_s
      expect_valid = test["valid"].as_bool

      if expect_valid
        seeds, options, credentials, default_db = Mongo::URI.parse(uri_string, Mongo::Options.new)

        if cred_json = test["credential"]?
          if cred_json.as_h.has_key?("username")
            credentials.username.should eq(cred_json["username"].as_s?)
          end
          if cred_json.as_h.has_key?("password")
            credentials.password.should eq(cred_json["password"].as_s?)
          end
          if cred_json.as_h.has_key?("source")
            credentials.source.should eq(cred_json["source"].as_s?)
          end
          if cred_json.as_h.has_key?("mechanism")
            if cred_json["mechanism"].raw.nil?
              credentials.mechanism.should be_nil
            else
              credentials.mechanism.should eq(cred_json["mechanism"].as_s)
            end
          end

          if expected_props = cred_json["mechanism_properties"]?.try(&.as_h?)
            actual_props_str = credentials.mechanism_properties || ""
            actual_props = actual_props_str.split(',').reject(&.empty?).to_h do |pair|
              k, v = pair.split(':', 2)
              {k.upcase, v}
            end

            expected_props.each do |k, v|
              actual_props[k.upcase]?.should eq(v.as_s)
            end
          end
        end
      else
        expect_raises(Mongo::Error) do
          Mongo::URI.parse(uri_string, Mongo::Options.new)
        end
      end
    end
  end
end
