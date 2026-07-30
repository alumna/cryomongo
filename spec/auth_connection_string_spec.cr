require "./spec_helper"
require "./sharding"

describe "Auth Connection String (Legacy)" do
  # Gather all JSON files and sort them deterministically
  files = Dir.glob("spec/tests/legacy/auth/**/*.json").sort

  # Dynamically filter the files using our cost-aware bin-packing algorithm
  files = Mongo::SpecSharding.filter(files)

  files.each do |file|
    it "executes: #{file}" do
      json_data = File.read(file)
      test_suite = JSON.parse(json_data)

      test_suite["tests"].as_a.each do |test|
        uri_string = test["uri"].as_s
        expect_valid = test["valid"].as_bool
        description = test["description"].as_s

        # 2025-09-30 Spec Update forbids AWS credentials/properties in URI,
        # conflicting with older tests in the legacy suite.
        # We check the raw string for userinfo or auth properties to cleanly skip them.
        if expect_valid && uri_string.includes?("MONGODB-AWS")
          has_userinfo = uri_string =~ %r{//[^/@]*@}
          has_props = uri_string.includes?("authMechanismProperties")
          next if has_userinfo || has_props
        end

        if expect_valid
          begin
            seeds, options, credentials, default_db = Mongo::URI.parse(uri_string, Mongo::Options.new)

            # `.try(&.as_h?)` safely handles missing keys AND explicit JSON nulls!
            if cred_json = test["credential"]?.try(&.as_h?)
              if cred_json.has_key?("username")
                credentials.username.should eq(cred_json["username"].as_s?), "Failed on: #{description}"
              end
              if cred_json.has_key?("password")
                credentials.password.should eq(cred_json["password"].as_s?), "Failed on: #{description}"
              end
              if cred_json.has_key?("source")
                credentials.source.should eq(cred_json["source"].as_s?), "Failed on: #{description}"
              end
              if cred_json.has_key?("mechanism")
                if cred_json["mechanism"].raw.nil?
                  credentials.mechanism.should be_nil, "Failed on: #{description}"
                else
                  credentials.mechanism.should eq(cred_json["mechanism"].as_s), "Failed on: #{description}"
                end
              end

              if expected_props = cred_json["mechanism_properties"]?.try(&.as_h?)
                actual_props_str = credentials.mechanism_properties || ""
                actual_props = actual_props_str.split(',').reject(&.empty?).to_h do |pair|
                  k, v = pair.split(':', 2)
                  {k.upcase, v}
                end

                expected_props.each do |k, v|
                  actual_props[k.upcase]?.should eq(v.as_s), "Failed on: #{description}"
                end
              end
            end
          rescue e : Exception
            fail "Expected URI to be valid, but raised #{e.class}: #{e.message}\nTest: #{description}\nURI: #{uri_string}"
          end
        else
          # Valid: false expected
          begin
            Mongo::URI.parse(uri_string, Mongo::Options.new)
            fail "Expected Mongo::Error but nothing was raised.\nTest: #{description}\nURI: #{uri_string}"
          rescue e : Mongo::Error
            # Passed
          rescue e : Exception
            fail "Expected Mongo::Error but got #{e.class}: #{e.message}\nTest: #{description}\nURI: #{uri_string}"
          end
        end
      end
    end
  end
end
