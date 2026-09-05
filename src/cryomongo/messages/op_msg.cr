require "bson"
require "./message_part"
require "./op_code"
require "./owned_receive"

# OP_MSG is an extensible message format designed to subsume the functionality of other opcodes.
# Class: Connection.receive copies this and drops Message. A class field on a
# struct is not a Darwin GC root (Wave 47). Outgoing uses the same type
# (split send/receive is not cheap: every command builds OpMsg).
# Wave 55: error? / body walk through OwnedReceive#view (pin.bytes), not
# only an ensure local. SectionBody also holds the owner class.
class Mongo::Messages::OpMsg < Mongo::Messages::Part
  @[Field(ignore: true)]
  getter op_code : OpCode = OpCode::Msg

  # Heap owner for the owned receive copy. BSON.view uses interior slices
  # of owner.bytes. Keep this on the class (Wave 52). A class pointer on
  # a struct OpMsg is not enough on Darwin (Wave 47). Outgoing messages
  # leave this nil. Do not serialize (OwnedReceive is not a Part field).
  # Wave 55: the walk must call owner.view / owner.fetch. A pin only in
  # ensure is dropped on ubuntu-26.04.
  @[Field(ignore: true)]
  @frame : OwnedReceive? = nil

  @[Flags]
  enum Flags : Int32
    ChecksumPresent
    MoreToCome
    ExhaustAllowed  = 1 << 16
  end

  getter flag_bits : Flags
  getter sections : Array(Part)
  getter checksum : UInt32?

  def initialize(@flag_bits : Flags, @sections, @checksum = nil)
  end

  def initialize(body, *, flag_bits : Flags = :none)
    initialize(
      flag_bits: flag_bits,
      sections: [
        Messages::OpMsg::SectionBody.new(BSON.new(body)),
      ].map(&.as(Messages::Part))
    )
  end

  def initialize(io : IO, header : Messages::Header)
    size = header.body_size
    msg_bytes = Messages::BufferPool.checkout(size)
    begin
      Messages.read_exact(io, msg_bytes[0, size])
    rescue error
      Messages::BufferPool.checkin(msg_bytes)
      raise error
    end
    # Copy then checkin before any BSON.view. own_payload after view still
    # left a window: nested []? is a view, and preview_mt can overwrite the
    # pool while error? walks body. Receive types are classes (Wave 52).
    initialize(Messages::BufferPool.copy_and_checkin(msg_bytes, size), header, used: size)
  end

  # *msg_bytes* must stay valid for the life of this message. The IO path
  # passes an owned copy after checkin. Inflate / specs pass their own Bytes.
  # Wrap that copy in OwnedReceive on this class. Do not checkin here: that
  # would pool the copy and invalidate nested []?.
  def initialize(msg_bytes : Bytes, header : Messages::Header, used : Int32 = msg_bytes.size)
    owner = OwnedReceive.new(msg_bytes)
    @frame = owner
    view_bytes = owner.bytes[0, used]
    msg_view = IO::Memory.new(view_bytes, writable: false)

    @flag_bits = Flags.from_value(msg_view.read_bytes(UInt32, IO::ByteFormat::LittleEndian))
    @sections = [] of Messages::Part
    @checksum = nil

    has_checksum = @flag_bits.checksum_present?
    limit_pos = used - (has_checksum ? 4 : 0)

    while msg_view.pos < limit_pos
      payload_type = msg_view.read_bytes(UInt8, IO::ByteFormat::LittleEndian)

      case payload_type
      when 0_u8
        payload = Messages.read_bson_view(view_bytes, msg_view)
        # SectionBody holds the same owner. A pin only on OpMsg#error?
        # ensure is dropped (Wave 55).
        @sections << SectionBody.new(payload, owner)
      when 1_u8
        marker = msg_view.pos
        sequence_size = msg_view.read_bytes(Int32, IO::ByteFormat::LittleEndian)

        sequence_identifier = msg_view.gets('\0', chomp: true)
        raise Mongo::Error.new("Invalid OP_MSG: EOF while reading sequence identifier") unless sequence_identifier

        contents = Array(BSON).new

        while msg_view.pos - marker < sequence_size
          contents << Messages.read_bson_view(view_bytes, msg_view)
        end

        @sections << SectionDocumentSequence.new(
          payload: SectionDocumentSequence::SectionPayload.new(
            sequence_identifier, contents
          ),
          owner: owner
        )
      else
        raise Mongo::Error.new "Received invalid payload type: #{payload_type}"
      end
    end

    if has_checksum
      @checksum = msg_view.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
    end
  end

  # Part is a class, so sections must be classes too.
  class SectionBody < Part
    getter payload_type : UInt8 = 0_u8
    getter payload : BSON
    # Heap owner for payload's interior slice. error? uses pin.bytes
    # through OwnedReceive#view. This class field is a second GC root
    # while the section is live (Wave 55). Outgoing leaves this nil.
    # Do not serialize.
    @[Field(ignore: true)]
    getter owner : OwnedReceive?

    def initialize(@payload : BSON, @owner : OwnedReceive? = nil); end
  end

  class SectionDocumentSequence < Part
    getter payload_type : UInt8 = 1_u8
    getter payload : SectionPayload
    # Same owner as SectionBody for sequence BSON.view slices (Wave 55).
    @[Field(ignore: true)]
    getter owner : OwnedReceive?

    def initialize(@payload : SectionPayload, @owner : OwnedReceive? = nil); end

    class SectionPayload < Part
      getter sequence_size : Int32 = 0
      getter sequence_identifier : String
      getter contents : Array(BSON)

      def initialize(@sequence_identifier, @contents)
        @sequence_size = self.part_size
      end
    end
  end

  def body : BSON
    pin = @frame
    with_owner_view(body_payload, pin)
  end

  def each_sequence(&)
    sections.each do |section|
      if section.is_a?(SectionDocumentSequence)
        yield section.payload.sequence_identifier, section.payload.contents
      end
    end
  end

  def sequence(key : String, contents : Array(BSON))
    @sections << SectionDocumentSequence.new(
      payload: SectionDocumentSequence::SectionPayload.new(
        sequence_identifier: key,
        contents: contents
      )
    )
  end

  def valid?
    pin = @frame
    payload = body_payload
    if owner = pin
      owner.must_fetch(payload, "ok") == 1
    else
      payload["ok"] == 1
    end
  end

  def error? : Exception?
    pin = @frame
    cached_body = with_owner_view(body_payload, pin)
    error_walk(cached_body, pin)
  end

  # failCommand may put labels on the reply or inside writeConcernError.
  # Clone first: the labels array is a nested view of the parent reply.
  # *pin* keeps the owner live while we copy (Wave 55).
  private def labels_from(value, pin : OwnedReceive? = nil) : Set(String)
    labels = Set(String).new
    if bson = clone_view?(value, pin)
      bson.each do |_, item|
        labels << item if item.is_a?(String)
      end
    end
    labels
  end

  # APM copy of the command or reply. Must not mutate the live body
  # (`BSON.new(BSON)` is a no-op). Sensitive commands become `{}`.
  def safe_payload(command)
    pin = @frame
    cached_body = with_owner_view(body_payload, pin)
    command_name = command.responds_to?(:name) ? command.name : ""
    if Mongo::Monitoring::Redact.sensitive?(command_name, cached_body)
      return Mongo::Monitoring::Redact::EMPTY
    end

    BSON.build do |builder|
      # Rebuild from pin.bytes inside the build so the owner stays
      # live for each nested value (Wave 55). Do not clone ok:1 hello.
      walk = with_owner_view(cached_body, pin)
      walk.each { |key, value, code|
        if value.is_a?(BSON) && code.array?
          builder.append_array(key, value)
        else
          builder[key] = value
        end
      }
      each_sequence do |key, contents|
        builder[key] = contents
      end
    end
  end

  # Body section payload. Interior view of the owned receive copy.
  private def body_payload : BSON
    sections.each do |section|
      return section.payload if section.is_a?(SectionBody)
    end
    raise Mongo::Error.new("Invalid OP_MSG: Missing body section")
  end

  # Rebuild *payload* from pin.bytes so LLVM cannot drop the owner.
  private def with_owner_view(payload : BSON, pin : OwnedReceive?) : BSON
    if owner = pin
      owner.view(payload.data)
    else
      payload
    end
  end

  private def fetch_field(body : BSON, key : String, pin : OwnedReceive?)
    if owner = pin
      owner.fetch(body, key)
    else
      body[key]?
    end
  end

  private def must_field(body : BSON, key : String, pin : OwnedReceive?)
    if owner = pin
      owner.must_fetch(body, key)
    else
      body[key]
    end
  end

  private def clone_view(value, pin : OwnedReceive?) : BSON
    bson = value.as(BSON)
    if owner = pin
      Mongo::Error.own_document(owner.view(bson.data))
    else
      Mongo::Error.own_document(bson)
    end
  end

  private def clone_view?(value, pin : OwnedReceive?) : BSON?
    return unless value
    if bson = value.as?(BSON)
      clone_view(bson, pin)
    end
  end

  # Walk errorLabels / ok / writeErrors with pin.bytes on every fetch.
  # A pin only in ensure is dropped (Wave 55 ubuntu-26.04 SIGSEGV at
  # create_data_key insert_one). Do not clone every ok:1 hello.
  private def error_walk(cached_body : BSON, pin : OwnedReceive?) : Exception?
    err_label_set = labels_from(fetch_field(cached_body, "errorLabels", pin), pin)

    if must_field(cached_body, "ok", pin) == 1
      # Do not clone topologyVersion on ok:1 with no write errors (hello / ping).
      if errors = fetch_field(cached_body, "writeErrors", pin)
        Mongo::Error::CommandWrite.new(
          clone_view(errors, pin),
          error_labels: err_label_set,
          topology_version: clone_view?(fetch_field(cached_body, "topologyVersion", pin), pin)
        )
      elsif write_error = fetch_field(cached_body, "writeConcernError", pin)
        wc = clone_view(write_error, pin)
        labels_from(wc["errorLabels"]?).each { |label| err_label_set << label }
        Mongo::Error::WriteConcern.new(
          wc,
          error_labels: err_label_set,
          topology_version: clone_view?(fetch_field(cached_body, "topologyVersion", pin), pin)
        )
      end
    else
      err_msg = fetch_field(cached_body, "errmsg", pin).try(&.as(String))
      err_code_name = fetch_field(cached_body, "codeName", pin).try(&.as(String))
      err_code = fetch_field(cached_body, "code", pin)
      details = clone_view?(fetch_field(cached_body, "errInfo", pin), pin)
      topology_version = clone_view?(fetch_field(cached_body, "topologyVersion", pin), pin)
      base_backoff_ms = fetch_field(cached_body, "baseBackoffMS", pin).try { |v|
        v.as?(Int) ? v.as(Int).to_i64 : nil
      }
      reply = if owner = pin
                BSON.new(owner.view(cached_body.data).data)
              else
                BSON.new(cached_body.data)
              end
      Mongo::Error::Command.new(err_code, err_code_name, err_msg, details, error_labels: err_label_set, topology_version: topology_version, base_backoff_ms: base_backoff_ms, reply: reply)
    end
  end
end
