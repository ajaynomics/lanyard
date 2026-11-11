require "net/http"
require "uri"

module DurableAssistants
  # A person's Link wallet (docs/payments.md), over Link's HTTP API as its own
  # CLI uses it (github.com/stripe/link-cli): a device sign-in, then spend
  # requests that Link pushes to the person's phone to approve. Each approved
  # request is a one-time card for its exact amount. This file asks for
  # nothing else: no approval policy (Link's rules for paying without asking),
  # so every request waits for the person in Link's app.
  #
  # A card's number only passes through #card, on its way to the agent's
  # browser; no error raised here repeats a response body.
  module Link
    SIGN_IN = "https://login.link.com"
    API = "https://api.link.com"
    SCOPE = "userinfo:read payment_methods.agentic"
    TIMEOUT = 15 # seconds
    # Link's own bounds on a request: its largest amount, in the currency's
    # smallest unit, and how long the person has to approve it.
    LIMIT = 50_000
    APPROVE_WITHIN = 30.minutes

    class Error < StandardError
      attr_reader :code
      def initialize(message, code: nil)
        super(message)
        @code = code
      end
    end

    def self.setting(key) = DurableAssistants.config(:link, key).presence

    def self.configured? = setting(:client_id).present?
    def self.client_name = setting(:client_name) || DurableAssistants.config(:app, :name)
    def self.test_mode? = setting(:test_mode) == true

    # A device sign-in: a phrase for the person to enter at Link, and the code
    # this install then trades for tokens (#finish_sign_in).
    def self.start_sign_in
      answer = post_form("#{SIGN_IN}/device/code", client_id: setting(:client_id), scope: SCOPE,
        connection_label: client_name, client_hint: client_name)
      { "device_code" => answer.fetch("device_code"), "phrase" => answer.fetch("user_code"),
        "url" => answer["verification_uri_complete"].presence || answer.fetch("verification_uri"),
        "expires_at" => answer.fetch("expires_in").to_i.seconds.from_now.to_i }
    end

    # The tokens, or nil while the person hasn't entered the phrase yet.
    def self.finish_sign_in(device_code)
      tokens(grant_type: "urn:ietf:params:oauth:grant-type:device_code", device_code: device_code)
    rescue Error => error
      return if error.code.in?(%w[ authorization_pending slow_down ])
      raise
    end

    def self.refresh(refresh_token) = tokens(grant_type: "refresh_token", refresh_token: refresh_token)

    def self.revoke(token) = post_form("#{SIGN_IN}/device/revoke", client_id: setting(:client_id), token: token)

    # A request for a one-time card, pushed to the person's Link app at once.
    # The key makes a repeat the same request, never a second push.
    def self.create(token, key:, amount:, currency:, merchant_name:, merchant_url:, context:)
      api(token, :post, "/spend_requests", { idempotency_key: key, amount: amount, currency: currency, merchant_name: merchant_name,
        merchant_url: merchant_url, context: context, credential_type: "card", request_approval: true, test: test_mode? }.compact)
    end

    def self.retrieve(token, id) = api(token, :get, "/spend_requests/#{escape(id)}")

    # The approved request's card, number included: for the agent's browser
    # alone (Invocation#redeem_card), never kept.
    def self.card(token, id) = api(token, :get, "/spend_requests/#{escape(id)}?include=card").fetch("card")

    # Closes the request, and its card if it has one.
    def self.cancel(token, id) = api(token, :post, "/spend_requests/#{escape(id)}/cancel", {})

    def self.tokens(**form)
      answer = post_form("#{SIGN_IN}/device/token", client_id: setting(:client_id), **form)
      { "access_token" => answer.fetch("access_token"), "refresh_token" => answer.fetch("refresh_token"),
        "expires_at" => answer.fetch("expires_in").to_i.seconds.from_now.to_i }
    end

    def self.post_form(url, **form)
      request = Net::HTTP::Post.new(URI(url), "Accept" => "application/json")
      request.set_form_data(form.compact)
      perform(request)
    end

    def self.api(token, method, path, body = nil)
      request = Net::HTTP.const_get(method.to_s.capitalize).new(URI("#{API}#{path}"),
        "Authorization" => "Bearer #{token}", "Accept" => "application/json", "Content-Type" => "application/json")
      request.body = body.to_json if body
      perform(request)
    end

    # Link's error code and message, never the body: a card's would hold its number.
    def self.perform(request)
      uri = request.uri
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: TIMEOUT, read_timeout: TIMEOUT) { it.request(request) }
      answer = JSON.parse(response.body) rescue nil
      return answer if response.is_a?(Net::HTTPSuccess) && answer.is_a?(Hash)
      error = answer.is_a?(Hash) ? answer["error"] : nil
      code = error.is_a?(Hash) ? error["code"] : error
      message = (error.is_a?(Hash) ? error["message"] : answer&.dig("error_description")).to_s.truncate(200)
      raise Error.new("Link answered HTTP #{response.code}#{" (#{code})" if code}#{": #{message}" if message.present?}", code: code)
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError, OpenSSL::SSL::SSLError => error
      raise Error, "Couldn't reach Link (#{error.class})."
    end

    def self.escape(id) = ERB::Util.url_encode(id.to_s)
  end
end
