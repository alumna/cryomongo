require "dns"
require "dns/resource/srv"

class Mongo::SRV
  # One verified SRV target plus the TTL of that DNS record.
  record Host,
    address : String,
    ttl : Time::Span

  def initialize(@url : String, @service_name : String = "mongodb")
  end

  # Initial seedlist lookup. Raises when DNS fails or no verified hosts exist.
  def resolve
    hosts, txt_record = lookup(raise_on_error: true)
    {hosts, txt_record}
  end

  # Periodic rescan. On DNS error or no verified hosts, returns an empty list
  # (the topology is left unchanged).
  def poll : {Array(Host), Time::Span}
    hosts, _txt = lookup(raise_on_error: false)
    min_ttl = hosts.min_of?(&.ttl) || 60.seconds
    if min_ttl < 60.seconds
      min_ttl = 60.seconds
    end
    {hosts, min_ttl}
  end

  def self.parent_domain(hostname : String) : String
    parts = hostname.downcase.rstrip('.').split(".", 2)
    parts.size < 2 ? hostname.downcase.rstrip('.') : parts[1]
  end

  def self.valid_target?(target : String, srv_hostname : String) : Bool
    host = target.downcase.rstrip('.')
    srv = srv_hostname.downcase.rstrip('.')
    parent = parent_domain(srv)
    return false if parent.empty?

    unless host == parent || host.ends_with?(".#{parent}")
      return false
    end

    srv_labels = srv.split('.').size
    host_labels = host.split('.').size
    if srv_labels < 3 && host_labels <= srv_labels
      return false
    end
    true
  end

  def self.limit_hosts(hosts : Array(Host), max : Int32) : Array(Host)
    return hosts if max <= 0 || max >= hosts.size
    copy = hosts.dup
    (copy.size - 1).downto(1) do |i|
      j = Random.rand(i + 1)
      copy.swap(i, j)
    end
    copy[0, max]
  end

  private def lookup(*, raise_on_error : Bool)
    parts = @url.split(".", 2)
    if parts.size < 2
      raise Mongo::Error.new("Top Level Domain is missing: #{@url}") if raise_on_error
      return {[] of Host, nil.as(DNS::Resource::TXT?)}
    end
    hostname, domainname = parts
    domain = "#{hostname}.#{domainname}"
    service = "_#{@service_name}._tcp.#{domain}"

    hosts = [] of Host
    txt_record : DNS::Resource::TXT? = nil

    begin
      DNS.query(service, [DNS::RecordType::SRV]) do |answer|
        resource = answer.resource
        next unless resource.is_a?(DNS::Resource::SRV)

        unless self.class.valid_target?(resource.target, @url)
          if raise_on_error
            raise Mongo::Error.new("SRV record has an invalid domain name: #{resource.target}")
          else
            Mongo::Log.warn { "Ignoring SRV target with a different parent domain: #{resource.target}" }
            next
          end
        end

        target = resource.target.downcase.rstrip('.')
        ttl = answer.ttl
        ttl = 60.seconds if ttl < 60.seconds
        hosts << Host.new("#{target}:#{resource.port}", ttl)
      end
    rescue e
      if raise_on_error
        raise e
      else
        Mongo::Log.warn { "SRV poll failed for #{service}: #{e}" }
        return {[] of Host, nil.as(DNS::Resource::TXT?)}
      end
    end

    if raise_on_error
      DNS.query(domain, [DNS::RecordType::TXT]) do |answer|
        txt_record = answer.resource.as(DNS::Resource::TXT)

        number_of_txt_records = txt_record.text_data.size
        if number_of_txt_records != 1
          raise Mongo::Error.new("#{number_of_txt_records} TXT records were found when querying the DNS, but a single record is supported.")
        end
      end
    end

    if hosts.empty? && raise_on_error
      raise Mongo::Error.new("No SRV records found when querying url: #{@url}")
    end

    {hosts, txt_record}
  end
end

