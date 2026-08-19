require "uri"
require "./srv"
require "./seed"
require "./options"
require "../connection/*"

# :nodoc:
module Mongo::URI
  extend self

  FORBIDDEN_DATABASE_CHARACTERS = {
    '/', '\\', ' ', '"', '$',
  }

  def parse(uri : String, options : Mongo::Options) : Tuple(Array(Seed), Mongo::Options, Mongo::Credentials, String)
    parts = uri.split("://", 2)
    raise Mongo::Error.new("Invalid scheme") unless parts.size == 2
    scheme, scheme_rest = parts

    raise Mongo::Error.new("Invalid scheme") unless scheme == "mongodb" || scheme == "mongodb+srv"

    # Hosts end at the first '/' that comes before any '?', or at '?' when the
    # delimiting slash is omitted. The connection-string spec allows both
    # mongodb://host/?k=v and mongodb://host?k=v (2023-08-02). Crystal's URI
    # parser treats everything after '?' as the query, so reconstructing
    # mongodb://host?k=v/ would keep a trailing slash in the last option value.
    query_idx = scheme_rest.index('?')
    slash_idx = scheme_rest.index('/')
    host_part : String
    rest : String?

    if slash_idx && (query_idx.nil? || slash_idx < query_idx)
      host_part = scheme_rest[0, slash_idx]
      rest = scheme_rest[(slash_idx + 1)..]
    elsif query_idx
      host_part = scheme_rest[0, query_idx]
      rest = scheme_rest[query_idx..]
    else
      host_part = scheme_rest
      rest = nil
    end

    seeds = host_part.split(",")
    raise Mongo::Error.new("Invalid host") if seeds.any?(&.empty?)

    parsed_uri = ::URI.parse("#{scheme}://#{seeds[0]}/#{rest}")

    if parsed_uri.userinfo && (parsed_uri.user.nil? || parsed_uri.user.try(&.empty?))
      raise Mongo::Error.new("Userinfo provided but username is empty")
    end

    # Extract as a mutable copy we can pass to the options parser without pretending the URI is updated
    query_params = parsed_uri.query_params

    if query_params.has_key?("authSource") && query_params["authSource"].empty?
      raise Mongo::Error.new("authSource cannot be empty")
    end

    if scheme == "mongodb+srv"
      if seeds.size > 1
        raise Mongo::Error.new("Cannot specify more than one host name in a connection string with the mongodb+srv protocol.")
      end
      if parsed_uri.port
        raise Mongo::Error.new("Cannot specify a port in a connection string with the mongodb+srv protocol.")
      end
      if resolver = options.dns_resolver
        DNS.default_resolver = resolver
      end

      host = parsed_uri.host
      raise Mongo::Error.new("Missing host in connection URI") unless host

      srv = Mongo::SRV.new(host)
      srv_records, txt_record = srv.resolve
      seeds = srv_records.map { |srv_record|
        "#{srv_record.target}:#{srv_record.port}"
      }

      query_params["ssl"] = "true" unless query_params.has_key?("ssl")
      txt_record.try { |txt|
        txt_options = ::URI::Params.parse(txt.text_data.join(" "))
        {"authSource", "replicaSet"}.each do |key|
          if txt_options.has_key?(key) && !query_params.has_key?(key)
            query_params[key] = txt_options[key]
          end
        end

        txt_options.each do |option, _|
          case option
          when "authSource", "replicaSet", "loadBalanced"
            # ok
          else
            raise Mongo::Error.new("Invalid TXT record option: #{option}")
          end
        end
      }
    end

    # Safe stripping of the leading slash without bounds exceptions
    default_auth_db = ::URI.decode(parsed_uri.path.lchop('/'))

    if default_auth_db.each_char.any?(&.in?(FORBIDDEN_DATABASE_CHARACTERS))
      raise Mongo::Error.new("Invalid database")
    end

    # Parse efficiently without concatenating the rest of the URI
    seeds = seeds.map do |seed|
      if seed.ends_with?(".sock")
        # Unix sockets are case-sensitive on the filesystem! Do not downcase.
        Seed.new(host: ::URI.decode(seed), port: 0)
      else
        seed_uri = ::URI.parse("mongodb://#{seed}")
        port = seed_uri.port || 27017
        raise Mongo::Error.new("Invalid port") if port < 1 || port > 65535

        Seed.new(
          host: seed_uri.host.try(&.downcase) || "localhost",
          port: port
        )
      end
    end

    options.mix_with_query_params(query_params)

    mech = options.auth_mechanism.try(&.upcase)
    default_source = default_auth_db.empty? ? nil : default_auth_db

    case mech
    when "GSSAPI", "MONGODB-X509", "MONGODB-AWS", "MONGODB-OIDC"
      default_source = "$external"
    when "PLAIN"
      default_source ||= "$external"
    else
      default_source ||= "admin"
    end

    mech_props_str = options.auth_mechanism_properties
    mech_props = parse_mechanism_properties(mech_props_str)

    # Inject the default SERVICE_NAME for GSSAPI without restructuring the entire string if it wasn't mutated
    if mech == "GSSAPI" && !mech_props.has_key?("SERVICE_NAME")
      mech_props["SERVICE_NAME"] = "mongodb"
      mech_props_str = mech_props_str ? "#{mech_props_str},SERVICE_NAME:mongodb" : "SERVICE_NAME:mongodb"
    end

    username = parsed_uri.user
    password = parsed_uri.password

    credentials = Mongo::Credentials.new(
      username: username ? ::URI.decode(username) : nil,
      password: password ? ::URI.decode(password) : nil,
      source: options.auth_source || default_source || "",
      mechanism: options.auth_mechanism,
      mechanism_properties: mech_props_str
    )

    validate_credentials(credentials, mech_props)

    raise Mongo::Error.new("directConnection=true cannot be provided with multiple seeds") if options.direct_connection && seeds.size > 1

    {seeds, options, credentials, default_auth_db}
  rescue e : ::URI::Error | ArgumentError | IndexError | Socket::Error
    # Catching expected parsing/network exceptions and wrapping them
    raise Mongo::Error.new("Invalid uri: #{uri}, #{e.message}", cause: e)
  end

  private def parse_mechanism_properties(props_str : String?) : Hash(String, String)
    return {} of String => String unless props_str

    props_str.split(',').reject(&.empty?).to_h do |pair|
      parts = pair.split(':', 2)
      if parts.size != 2
        raise Mongo::Error.new("Malformed authMechanismProperties: expected 'key:value', got '#{pair}'")
      end
      {parts[0].upcase, parts[1]}
    end
  end

  private def validate_credentials(cred : Mongo::Credentials, props : Hash(String, String))
    mech = cred.mechanism
    return unless mech

    case mech.upcase
    when "GSSAPI"
      raise Mongo::Error.new("GSSAPI requires a username") if cred.username.nil? || cred.username.try(&.empty?)
      raise Mongo::Error.new("GSSAPI requires authSource to be $external") if cred.source && cred.source != "$external"
      if canon = props["CANONICALIZE_HOST_NAME"]?
        # BUGFIX: Ensure canon is upcased before validating
        unless ["TRUE", "FALSE", "NONE", "FORWARD", "FORWARDANDREVERSE"].includes?(canon.upcase)
          raise Mongo::Error.new("Invalid CANONICALIZE_HOST_NAME: #{canon}")
        end
      end
    when "MONGODB-X509"
      raise Mongo::Error.new("MONGODB-X509 does not support passwords") if cred.password
      raise Mongo::Error.new("MONGODB-X509 requires authSource to be $external") if cred.source && cred.source != "$external"
    when "PLAIN"
      raise Mongo::Error.new("PLAIN requires a username") if cred.username.nil? || cred.username.try(&.empty?)
    when "SCRAM-SHA-1", "SCRAM-SHA-256"
      raise Mongo::Error.new("#{mech} requires a username") if cred.username.nil? || cred.username.try(&.empty?)
    when "MONGODB-AWS"
      # 2025-09-30 Spec Update: AWS credentials & properties must not be provided in the URI.
      if cred.username || cred.password
        raise Mongo::Error.new("MONGODB-AWS credentials cannot be provided in the URI")
      end
      if !props.empty?
        raise Mongo::Error.new("MONGODB-AWS authentication properties cannot be provided in the URI")
      end
    when "MONGODB-OIDC"
      raise Mongo::Error.new("MONGODB-OIDC does not support passwords") if cred.password
      env = props["ENVIRONMENT"]?
      unless env
        raise Mongo::Error.new("MONGODB-OIDC requires ENVIRONMENT")
      end

      allowed_props = {"ENVIRONMENT", "TOKEN_RESOURCE"}
      props.each_key do |k|
        raise Mongo::Error.new("Unsupported property for MONGODB-OIDC: #{k}") unless allowed_props.includes?(k)
      end

      case env.downcase
      when "test"
        raise Mongo::Error.new("MONGODB-OIDC test environment does not support username") if cred.username
      when "azure", "gcp"
        raise Mongo::Error.new("MONGODB-OIDC #{env} requires TOKEN_RESOURCE") unless props.has_key?("TOKEN_RESOURCE")
        raise Mongo::Error.new("MONGODB-OIDC #{env} does not support passwords") if cred.password
      when "k8s"
        raise Mongo::Error.new("MONGODB-OIDC k8s does not support username/password") if cred.username || cred.password
      else
        raise Mongo::Error.new("Unsupported MONGODB-OIDC environment: #{env}")
      end
    end
  end
end
