require "async"
require "async/http"

module DurableAssistants
  # Apple's push service, for the phone app's notifications (Push::Device):
  # one notice to one device token, over HTTP/2, signed with the install's
  # APNs key as a short-lived token (ES256). Web Push stays for browsers.
  # Without every setting (config/apns.yml) it is off: nothing is sent and
  # the app offers no notifications of its own. A notice's words never reach
  # the log, nor does a device token.
  module Apns
    HOSTS = { "production" => "https://api.push.apple.com", "sandbox" => "https://api.sandbox.push.apple.com" }.freeze
    # Apple refuses a token older than an hour and throttles one renewed more
    # often than every twenty minutes.
    TOKEN_LIFETIME = 50.minutes
    TIMEOUT = 10 # seconds

    # What Apple said: its HTTP status, and its reason for a refusal
    # ("Unregistered", "BadDeviceToken"), never the notice.
    Response = Data.define(:status, :reason) do
      def sent? = status == 200
      # The device no longer has the app, or the token was never one of this app's.
      def gone? = status == 410 || reason.in?(%w[ BadDeviceToken Unregistered DeviceTokenNotForTopic ])
    end

    def self.setting(key) = DurableAssistants.config(:apns, key).presence

    def self.configured? = %i[ key_id team_id private_key topic ].all? { setting(it) }

    # Priority 10 sends it at once; 5 when it suits the device's battery.
    def self.deliver(token:, environment:, payload:, collapse_id: nil, priority: 10)
      headers = { "authorization" => "bearer #{bearer}", "apns-topic" => setting(:topic), "apns-push-type" => "alert",
        "apns-priority" => priority.to_s, "apns-expiration" => 1.day.from_now.to_i.to_s, "content-type" => "application/json" }
      headers["apns-collapse-id"] = collapse_id.to_s.first(64) if collapse_id
      post HOSTS.fetch(environment), "/3/device/#{token}", headers, payload.to_json
    end

    # The provider token: the key's id and the team, signed with the key, for
    # TOKEN_LIFETIME. Made again when it is older, or the key changed.
    def self.bearer(now: Time.current)
      key = [ setting(:key_id), setting(:team_id), setting(:private_key) ]
      @bearer = nil unless @bearer && @bearer[:key] == key && @bearer[:at] > now - TOKEN_LIFETIME
      (@bearer ||= { key: key, at: now, token: sign(*key, issued_at: now.to_i) })[:token]
    end

    def self.sign(key_id, team_id, private_key, issued_at:)
      encode = ->(value) { Base64.urlsafe_encode64(value, padding: false) }
      input = [ encode.({ alg: "ES256", kid: key_id }.to_json), encode.({ iss: team_id, iat: issued_at }.to_json) ].join(".")
      # OpenSSL signs in DER; a JWT carries the two numbers side by side, 32 bytes each.
      der = OpenSSL::PKey::EC.new(private_key.gsub("\\n", "\n")).sign("SHA256", input)
      raw = OpenSSL::ASN1.decode(der).value.map { it.value.to_s(2).rjust(32, "\x00") }.join
      "#{input}.#{encode.(raw)}"
    end

    def self.post(host, path, headers, body)
      Sync do |task|
        task.with_timeout(TIMEOUT) do
          client = Async::HTTP::Client.new(Async::HTTP::Endpoint.parse(host, protocol: Async::HTTP::Protocol::HTTP2))
          response = client.post(path, headers.to_a, body)
          answer = response.read.to_s
          Response.new(response.status, (JSON.parse(answer)["reason"] if answer.present?))
        ensure
          client&.close
        end
      end
    rescue Async::TimeoutError, SystemCallError, IOError, OpenSSL::SSL::SSLError, SocketError, JSON::ParserError => error
      Response.new(0, error.class.name)
    end
  end
end
