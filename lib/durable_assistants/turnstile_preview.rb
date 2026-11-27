require "net/http"

module DurableAssistants
  # A typed widget create and a single preview binding; no deploy or promotion.
  class TurnstilePreview
    class Error < StandardError; end

    API_HOST = "api.cloudflare.com".freeze
    SITEKEY = /\A0x[A-Za-z0-9_-]{15,64}\z/
    SECRET = /\A[A-Za-z0-9_-]{20,256}\z/
    MAX_RESPONSE = 16.kilobytes
    UNKNOWN = "Cloudflare did not confirm the preview widget outcome. Check Cloudflare before trying again.".freeze

    def initialize(destination)
      @destination = destination
      @widgets = "/client/v4/accounts/#{destination.account_id}/challenges/widgets"
    end

    def create(name:)
      vault = Vault.new(@destination)
      token, pages_token = @destination.resource_ids.map { |record| vault.read(record) }
      raise Error, "The preview requires separate Turnstile and Pages credentials.", cause: nil if token == pages_token
      pages = Pages.new(@destination, pages_token, method(:request))
      pages.check!
      code, body = request(Net::HTTP::Post.new(@widgets), token, json: {
        name: name, domains: [ @destination.hostname ], mode: "managed"
      })
      raise Error, "Cloudflare refused the preview widget request (HTTP #{code}).", cause: nil if (400..499).cover?(code)
      widget = confirmed_result(code, body)
      sitekey, secret = widget.values_at("sitekey", "secret")
      raise Error, UNKNOWN, cause: nil unless public_key?(sitekey, token, pages_token, secret)
      unless widget["domains"] == [ @destination.hostname ] && secret.is_a?(String) && SECRET.match?(secret) &&
          !secret.include?(token) && !secret.include?(pages_token)
        revoke_failed_widget(sitekey, token)
      end

      case pages.bind(secret)
      when :bound
        { status: "created", sitekey: sitekey }
      when :rejected
        revoke_failed_widget(sitekey, token)
      else
        raise Error, "Could not confirm the Pages binding for preview widget #{sitekey}. Check Pages and Cloudflare before trying again.", cause: nil
      end
    end

    private
      def public_key?(sitekey, *private_values)
        sitekey.is_a?(String) && SITEKEY.match?(sitekey) &&
          private_values.none? { |value| value.is_a?(String) && value.present? && sitekey.include?(value) }
      end

      def revoke_failed_widget(sitekey, token)
        if revoked?(sitekey, token)
          raise Error, "The preview widget was revoked. Check Pages and Cloudflare before trying again.", cause: nil
        end
        raise Error, "Could not confirm cleanup of preview widget #{sitekey}. Check Pages and Cloudflare before trying again.", cause: nil
      end

      def revoked?(sitekey, token)
        code, body = request(Net::HTTP::Delete.new("#{@widgets}/#{sitekey}"), token)
        (200..299).cover?(code) && body.is_a?(Hash) && body["success"] == true &&
          (body["result"].nil? || (body["result"].is_a?(Hash) && body["result"]["sitekey"] == sitekey))
      rescue Error
        false
      end

      def confirmed_result(code, body)
        return body["result"] if (200..299).cover?(code) && body.is_a?(Hash) && body["success"] == true && body["result"].is_a?(Hash)
        raise Error, UNKNOWN, cause: nil
      end

      def request(message, token, json: nil)
        message["Authorization"] = "Bearer #{token}"
        if json
          message["Content-Type"] = "application/json"
          message.body = json.to_json
        end
        http = Net::HTTP.new(API_HOST, 443, nil)
        http.use_ssl = true
        http.open_timeout = http.read_timeout = http.write_timeout = 10
        http.max_retries = 0
        http.start do
          http.request(message) do |response|
            code = response.code.to_i
            return [ code, nil ] unless (200..299).cover?(code) || Pages::REJECTED.include?(code)
            body = String.new
            response.read_body do |bytes|
              raise Error, UNKNOWN, cause: nil if body.bytesize + bytes.bytesize > MAX_RESPONSE
              body << bytes
            end
            return [ code, parse_body(body) ]
          end
        end
      rescue Error
        raise
      rescue StandardError
        # The transport/parser's message and its cause can contain the request or response.
        raise Error, UNKNOWN, cause: nil
      end

      def parse_body(body)
        JSON.parse(body)
      rescue JSON::ParserError
        nil
      end
  end
end
