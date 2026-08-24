require "./spec_helper"
require "openssl"
require "file_utils"

# OpenSSL 3 writes PKCS#8 (`BEGIN ENCRYPTED PRIVATE KEY`). That is the
# format most tools emit. PEM_read_bio_PrivateKey must accept it.
private def encrypted_client_pem(dir : String, password : String) : String
  key = File.join(dir, "client.key")
  crt = File.join(dir, "client.crt")
  pem = File.join(dir, "client.pem")
  status = Process.run(
    "openssl",
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
  status = Process.run(
    "openssl",
    ["rsa", "-in", File.join(dir, "client.key"), "-traditional", "-aes256", "-passin", "pass:#{password}", "-passout", "pass:#{password}", "-out", trad],
    error: Process::Redirect::Pipe,
    output: Process::Redirect::Pipe
  )
  status.success?.should be_true
  File.write(pem, File.read(trad) + File.read(File.join(dir, "client.crt")))
  pem
end

describe Mongo::TLS do
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
