require "base64"
require "openssl"

# A signed OpenAI event authenticates delivery, not the person calling.
class VoiceOffer
  MAX_BYTES = 32.kilobytes
  ID = /\A[A-Za-z0-9_-]{1,128}\z/

  def initialize(body, headers)
    @body, @id, @timestamp, @signature = body, headers["webhook-id"], headers["webhook-timestamp"], headers["webhook-signature"]
  end

  def signed_with?(secret)
    return false unless @body.bytesize <= MAX_BYTES && ID.match?(@id.to_s) && /\A[0-9]{1,12}\z/.match?(@timestamp.to_s)
    return false if (Time.current.to_i - @timestamp.to_i).abs > 5.minutes
    return false unless @signature.present? && @signature.bytesize <= 512 && secret.to_s.start_with?("whsec_")

    key = Base64.strict_decode64(secret.delete_prefix("whsec_"))
    return false if key.empty?
    expected = "v1,#{OpenSSL::HMAC.base64digest("SHA256", key, "#{@id}.#{@timestamp}.#{@body}")}"
    @signature.split.any? { |value| ActiveSupport::SecurityUtils.secure_compare(value, expected) }
  rescue ArgumentError
    false
  end

  # Its IDs, from a well-formed GPT-Live SIP offer ("Telephony and SIP":
  # live.transport.incoming, data.type "sip", data.session_id). Any caller may
  # reach the agent, and the gateway checks which number was called. Nil when
  # it isn't one; #refusal names the check.
  def identity
    event = JSON.parse(@body, max_nesting: 12, allow_duplicate_key: false)
    @refusal = check(event)
    return if @refusal

    { delivery_id: @id, event_id: event["id"], session_id: event.dig("data", "session_id"), body_digest: Digest::SHA256.hexdigest(@body) }
  rescue JSON::ParserError
    @refusal = "body is not JSON"
    nil
  end

  # Which check an offer failed, by name only: never a value or a header.
  attr_reader :refusal

  # The calling number, for Agent::VoiceCall::Reach to compare with the
  # owner's and nothing else: never kept, logged or told to the agent. The user
  # part of the one From header's sip:, sips: or tel: address; nil when there
  # isn't exactly one From, or its address isn't a number.
  def calling_number
    froms = sip_headers.select { |header| header["name"].to_s.downcase.in?(%w[ from f ]) }
    number_in(froms.sole["value"].to_s) if froms.one?
  end

  def caller_header_presence
    names = sip_headers.map { |header| header["name"].to_s.downcase }
    { from: names.intersect?(%w[ from f ]), asserted_identity: names.include?("p-asserted-identity") }
  end

  private
    def sip_headers
      Array(JSON.parse(@body).dig("data", "sip_headers")).grep(Hash)
    rescue JSON::ParserError, TypeError
      []
    end

    def check(event)
      return "event is not an object" unless event.is_a?(Hash)
      return "type is not live.transport.incoming" unless event["type"] == "live.transport.incoming"
      return "created_at is not a number" unless event["created_at"].is_a?(Numeric)
      return "event id is missing or malformed" unless event["id"].is_a?(String) && ID.match?(event["id"])
      data = event["data"]
      return "data is not an object" unless data.is_a?(Hash)
      return "data.type is not sip" unless data["type"] == "sip"
      "data.session_id is missing or malformed" unless data["session_id"].is_a?(String) && DurableAssistants::Live::SESSION.match?(data["session_id"])
    end

    # "Name" <sip:+14165550100@host>;tag=x, or the bare address: a quoted name
    # may hold anything, so it goes first, then whatever is outside <>.
    def number_in(from)
      address = from.sub(/\A\s*"(?:[^"\\]|\\.)*"/, "")
      address = address[/<([^<>]*)>/, 1] || address
      address[/\A\s*(?:sips?|tel):(\+?[\d.()-]+)(?=[@;]|\z)/i, 1]
    end
end
