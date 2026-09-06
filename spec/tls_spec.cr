require "./spec_helper"
require "openssl"
require "file_utils"

# OpenSSL 3 writes PKCS#8 (`BEGIN ENCRYPTED PRIVATE KEY`). That is the
# format most tools emit. PEM_read_bio_PrivateKey must accept it.
#
# GitHub macos-15 PATH openssl is Apple LibreSSL. pkg-config openssl there
# is Homebrew 1.1. Crystal can still load PKCS#8. `openssl rsa -traditional`
# needs OpenSSL 3. Prefer OPENSSL_BIN, then brew openssl@3, then pkg-config
# only when the module version is 3. Do not use 1.1 or LibreSSL for that
# conversion.

# Capture stdout. Nil when the binary is missing or the command fails.
private def capture_stdout(command : String, args : Array(String)) : String?
  return nil unless Process.find_executable(command)
  output = IO::Memory.new
  status = Process.run(command, args, output: output, error: Process::Redirect::Close)
  return nil unless status.success?
  text = output.to_s.strip
  text.empty? ? nil : text
end

# True for `openssl version` on OpenSSL 3.x. False for 1.1 and LibreSSL.
private def openssl3_version?(version_line : String) : Bool
  version_line.starts_with?("OpenSSL 3.")
end

# True for `pkg-config --modversion openssl` on 3.x. macos-15 Homebrew
# openssl@1.1 reports 1.1.1w.
private def openssl3_modversion?(modversion : String) : Bool
  modversion.starts_with?("3.")
end

private def openssl_version_line(bin : String) : String
  capture_stdout(bin, ["version"]) || ""
end

private def openssl_cli : String
  if env = ENV["OPENSSL_BIN"]?
    return env unless env.empty?
  end
  if prefix = capture_stdout("brew", ["--prefix", "openssl@3"])
    candidate = File.join(prefix, "bin", "openssl")
    return candidate if File::Info.executable?(candidate)
  end
  if openssl3_modversion?(capture_stdout("pkg-config", ["--modversion", "openssl"]) || "")
    if prefix = capture_stdout("pkg-config", ["--variable=prefix", "openssl"])
      candidate = File.join(prefix, "bin", "openssl")
      return candidate if File::Info.executable?(candidate)
    end
  end
  "openssl"
end

private def encrypted_client_pem(dir : String, password : String) : String
  key = File.join(dir, "client.key")
  crt = File.join(dir, "client.crt")
  pem = File.join(dir, "client.pem")
  status = Process.run(
    openssl_cli,
    ["req", "-x509", "-newkey", "rsa:2048", "-keyout", key, "-out", crt, "-days", "1", "-subj", "/CN=localhost", "-passout", "pass:#{password}"],
    error: Process::Redirect::Pipe,
    output: Process::Redirect::Pipe
  )
  status.success?.should be_true
  File.write(pem, File.read(key) + File.read(crt))
  pem
end

# Traditional PEM (`BEGIN RSA PRIVATE KEY` + Proc-Type ENCRYPTED).
private def encrypted_traditional_pem(dir : String, password : String) : String
  encrypted_client_pem(dir, password)
  trad = File.join(dir, "client.trad.key")
  pem = File.join(dir, "client.trad.pem")
  bin = openssl_cli
  version = openssl_version_line(bin)
  unless openssl3_version?(version)
    fail "#{bin} is not OpenSSL 3 (got #{version.inspect}; rsa -traditional needs 3, not 1.1 or LibreSSL)"
  end
  error = IO::Memory.new
  status = Process.run(
    bin,
    ["rsa", "-in", File.join(dir, "client.key"), "-traditional", "-aes256", "-passin", "pass:#{password}", "-passout", "pass:#{password}", "-out", trad],
    error: error,
    output: Process::Redirect::Close
  )
  unless status.success?
    fail "#{bin} rsa -traditional failed: #{error}"
  end
  File.write(pem, File.read(trad) + File.read(File.join(dir, "client.crt")))
  pem
end

describe Mongo::TLS do
  it "treats only OpenSSL 3 version lines as usable for rsa -traditional" do
    openssl3_version?("OpenSSL 3.5.5 30 Sep 2025").should be_true
    openssl3_version?("OpenSSL 3.0.13 30 Jan 2024").should be_true
    openssl3_version?("OpenSSL 1.1.1w  11 Sep 2023").should be_false
    openssl3_version?("LibreSSL 3.3.6").should be_false
  end

  it "ignores pkg-config openssl 1.1 when picking the CLI" do
    openssl3_modversion?("3.5.5").should be_true
    openssl3_modversion?("3.0.0").should be_true
    openssl3_modversion?("1.1.1w").should be_false
    openssl3_modversion?("1.1.1").should be_false
  end

  it "resolves an openssl binary (OpenSSL 3 when present)" do
    File.basename(openssl_cli).should eq "openssl"
    openssl3_version?(openssl_version_line(openssl_cli)).should be_true
  end

  it "loads an encrypted PEM when tlsCertificateKeyFilePassword is set" do
    dir = File.tempname("cryomongo-tls")
    Dir.mkdir_p(dir)
    begin
      pem = encrypted_client_pem(dir, "secret")
      context = OpenSSL::SSL::Context::Client.new
      options = Mongo::Options.new(
        tls_certificate_key_file: pem,
        tls_certificate_key_file_password: "secret",
        tls_disable_certificate_revocation_check: true
      )
      Mongo::TLS.configure(context, options)
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "rejects an encrypted PEM when the password is wrong" do
    dir = File.tempname("cryomongo-tls")
    Dir.mkdir_p(dir)
    begin
      pem = encrypted_client_pem(dir, "secret")
      context = OpenSSL::SSL::Context::Client.new
      options = Mongo::Options.new(
        tls_certificate_key_file: pem,
        tls_certificate_key_file_password: "wrong",
        tls_disable_certificate_revocation_check: true
      )
      expect_raises(OpenSSL::Error) do
        Mongo::TLS.configure(context, options)
      end
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "loads a traditional encrypted PEM when tlsCertificateKeyFilePassword is set" do
    dir = File.tempname("cryomongo-tls-trad")
    Dir.mkdir_p(dir)
    begin
      pem = encrypted_traditional_pem(dir, "secret")
      context = OpenSSL::SSL::Context::Client.new
      options = Mongo::Options.new(
        tls_certificate_key_file: pem,
        tls_certificate_key_file_password: "secret",
        tls_disable_certificate_revocation_check: true
      )
      Mongo::TLS.configure(context, options)
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
