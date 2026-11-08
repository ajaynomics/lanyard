require "net/http"
require "uri"

module DurableAssistants
  # Texts from an agent's own number, through voip.ms (docs/phone.md). Its API
  # password is the whole account's, with no narrower key, so this file is the
  # only code that holds it and may ask for exactly two things: send a text, or
  # send a longer one as MMS. Nothing reads the account, its numbers or its
  # messages.
  module Voipms
    URL = URI("https://voip.ms/api/v1/rest.php")
    METHODS = %w[ sendSMS sendMMS ].freeze
    SMS_LIMIT = 160 # characters; longer goes as one MMS, up to MMS_LIMIT
    MMS_LIMIT = 2048
    TIMEOUT = 15 # seconds

    class Error < StandardError; end

    def self.setting(key) = DurableAssistants.config(:voipms, key).presence

    def self.configured? = setting(:username).present? && setting(:password).present?

    # One text from `from` to `to`, both ten digits. voip.ms's id for it.
    def self.send_text(from:, to:, body:)
      method = body.length <= SMS_LIMIT ? "sendSMS" : "sendMMS"
      answer = request(method, did: from, dst: to, message: body)
      answer["sms"] || answer["mms"]
    end

    # A POST, so the password is never in a URL that something might log.
    def self.request(method, **params)
      raise ArgumentError, "voip.ms #{method} is not something this app asks for" unless METHODS.include?(method)
      post = Net::HTTP::Post.new(URL)
      post.set_form_data(api_username: setting(:username), api_password: setting(:password), method: method, **params)
      response = Net::HTTP.start(URL.host, URL.port, use_ssl: true, open_timeout: TIMEOUT, read_timeout: TIMEOUT) { it.request(post) }
      answer = JSON.parse(response.body) rescue {}
      return answer if response.is_a?(Net::HTTPSuccess) && answer["status"] == "success"
      raise Error, "voip.ms refused the text: #{answer["status"].presence || "HTTP #{response.code}"}"
    end
    private_class_method :request
  end
end
