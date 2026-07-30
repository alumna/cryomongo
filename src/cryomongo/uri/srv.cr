require "dns"
require "dns/resource/srv"

class Mongo::SRV
  def initialize(@url : String)
  end

  def resolve
    parts = @url.split(".", 2)
    raise Mongo::Error.new("Top Level Domain is missing: #{@url}") if parts.size < 2
    hostname, domainname = parts

    srv_records = [] of DNS::Resource::SRV
    txt_record : DNS::Resource::TXT? = nil

    # DNS shard executes sequentially by default when a block is provided.
    DNS.query("_mongodb._tcp.#{hostname}.#{domainname}", [DNS::RecordType::SRV]) do |answer|
      srv_record = answer.resource.as(DNS::Resource::SRV)

      # Safe extraction and case-insensitive comparison, ignoring trailing FQDN dots.
      target_parts = srv_record.target.downcase.rstrip('.').split(".", 2)
      if target_parts.size < 2 || target_parts[1] != domainname.downcase.rstrip('.')
        raise Mongo::Error.new("SRV record has an invalid domain name: #{srv_record.target}")
      end
      srv_records << srv_record
    end

    DNS.query("#{hostname}.#{domainname}", [DNS::RecordType::TXT]) do |answer|
      txt_record = answer.resource.as(DNS::Resource::TXT)

      number_of_txt_records = txt_record.text_data.size
      if number_of_txt_records != 1
        raise Mongo::Error.new("#{number_of_txt_records} TXT records were found when querying the DNS, but a single record is supported.")
      end
    end

    if srv_records.empty?
      raise Mongo::Error.new("No SRV records found when querying url: #{@url}")
    end

    {srv_records, txt_record}
  end
end
