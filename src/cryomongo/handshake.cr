# Client metadata for the MongoDB handshake. Cached after the first build.
# The `client` document must stay at or under 512 bytes.
module Mongo::Handshake
  extend self

  @@cached_env : BSON? = nil
  @@env_checked = false
  @@cached_os_name : String? = nil
  @@os_name_checked = false
  @@cached_os_version : String? = nil
  @@os_version_checked = false

  OS_TYPE = {{ flag?(:linux) ? "Linux" : flag?(:darwin) ? "Darwin" : flag?(:win32) ? "Windows" : "Unknown" }}

  OS_ARCH = {{ flag?(:x86_64) ? "x86_64" : flag?(:aarch64) ? "aarch64" : flag?(:i686) ? "i686" : "unknown" }}

  MAX_CLIENT_BYTES = 512
  MAX_APPNAME      = 128

  class DriverInfo
    getter name : String
    getter version : String?
    getter platform : String?

    def initialize(@name : String, @version : String? = nil, @platform : String? = nil)
      if name.includes?('|') || version.try(&.includes?('|')) || platform.try(&.includes?('|'))
        raise Mongo::Error.new("Handshake driver info must not contain '|'")
      end
    end

    def_equals @name, @version, @platform
  end

  # True on AWS Lambda / Azure Functions / GCP / Vercel. auto monitoring uses poll then.
  def faas? : Bool
    !faas_name.nil?
  end

  def os_name : String?
    return @@cached_os_name if @@os_name_checked
    @@os_name_checked = true
    @@cached_os_name = read_os_name
  end

  def os_version : String?
    return @@cached_os_version if @@os_version_checked
    @@os_version_checked = true
    @@cached_os_version = read_os_version
  end

  def platform : String
    "Crystal #{Crystal::VERSION}"
  end

  # Build the `client` metadata document. Truncate optional fields if it is too big.
  def client_document(
    appname : String?,
    extra : Array(DriverInfo) = [] of DriverInfo,
  ) : BSON
    if (name = appname) && name.bytesize > MAX_APPNAME
      raise Mongo::Error.new("appname must be at most #{MAX_APPNAME} bytes")
    end

    driver_name = "cryomongo"
    driver_version = Mongo::VERSION
    platform_str = platform
    extra.each do |info|
      driver_name = "#{driver_name}|#{info.name}"
      if ver = info.version
        driver_version = "#{driver_version}|#{ver}"
      end
      if plat = info.platform
        platform_str = "#{platform_str}|#{plat}"
      end
    end

    env = env_document
    os_n = os_name
    os_v = os_version
    omit_env_extra = false
    omit_os_extra = false
    omit_env = false

    loop do
      body = BSON.build do |builder|
        if name = appname
          builder["application"] = {name: name}
        end
        builder["driver"] = {name: driver_name, version: driver_version}
        builder.document("os") do
          builder["type"] = OS_TYPE
          unless omit_os_extra
            builder["name"] = os_n if os_n
            builder["architecture"] = OS_ARCH
            builder["version"] = os_v if os_v
          end
        end
        builder["platform"] = platform_str
        if env && !omit_env
          if omit_env_extra
            if env_name = env["name"]?.try(&.as?(String))
              builder.document("env") { builder["name"] = env_name }
            else
              builder["env"] = env
            end
          else
            builder["env"] = env
          end
        end
      end

      return body if body.size <= MAX_CLIENT_BYTES

      if env && !omit_env_extra && !omit_env
        omit_env_extra = true
      elsif !omit_os_extra
        omit_os_extra = true
      elsif env && !omit_env
        omit_env = true
      elsif platform_str.bytesize > 16
        platform_str = platform_str.byte_slice(0, 16)
      else
        return body
      end
    end
  end

  private def env_document : BSON?
    return @@cached_env if @@env_checked
    @@env_checked = true

    name = faas_name
    runtime = File.exists?("/.dockerenv") ? "docker" : nil
    orchestrator = ENV["KUBERNETES_SERVICE_HOST"]? ? "kubernetes" : nil
    has_container = runtime || orchestrator
    return nil unless name || has_container

    @@cached_env = BSON.build do |builder|
      builder["name"] = name if name
      add_faas_fields(builder, name) if name
      if has_container
        builder.document("container") do
          builder["runtime"] = runtime if runtime
          builder["orchestrator"] = orchestrator if orchestrator
        end
      end
    end
  end

  private def faas_name : String?
    vercel = ENV["VERCEL"]?
    aws = ENV["AWS_EXECUTION_ENV"]? || ENV["AWS_LAMBDA_RUNTIME_API"]?
    azure = ENV["FUNCTIONS_WORKER_RUNTIME"]?
    gcp = ENV["K_SERVICE"]? || ENV["FUNCTION_NAME"]?
    # vercel wins over aws.lambda. Any other mix is omitted.
    if vercel
      return "vercel"
    end
    count = 0
    count += 1 if aws
    count += 1 if azure
    count += 1 if gcp
    return nil if count != 1
    return "aws.lambda" if aws
    return "azure.func" if azure
    return "gcp.func" if gcp
    nil
  end

  private def add_faas_fields(builder : BSON::Builder, name : String) : Nil
    case name
    when "aws.lambda"
      if region = ENV["AWS_REGION"]?
        builder["region"] = region
      end
      if mem = ENV["AWS_LAMBDA_FUNCTION_MEMORY_SIZE"]?.try(&.to_i32?)
        builder["memory_mb"] = mem
      end
    when "gcp.func"
      if mem = ENV["FUNCTION_MEMORY_MB"]?.try(&.to_i32?)
        builder["memory_mb"] = mem
      end
      if timeout = ENV["FUNCTION_TIMEOUT_SEC"]?.try(&.to_i32?)
        builder["timeout_sec"] = timeout
      end
      if region = ENV["FUNCTION_REGION"]?
        builder["region"] = region
      end
    when "vercel"
      if region = ENV["VERCEL_REGION"]?
        builder["region"] = region
      end
    end
  end

  private def read_os_name : String?
    read_os_release("PRETTY_NAME=")
  end

  private def read_os_version : String?
    read_os_release("VERSION_ID=")
  end

  private def read_os_release(prefix : String) : String?
    path = "/etc/os-release"
    return nil unless File.exists?(path)
    File.each_line(path) do |line|
      if line.starts_with?(prefix)
        value = line.byte_slice(prefix.bytesize).strip
        value = value.strip('"')
        return value unless value.empty?
      end
    end
    nil
  rescue
    nil
  end
end
