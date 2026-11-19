require "net/http"
require "uri"

module DurableAssistants
  # Clio Manage's API v4 and its OAuth endpoints, with a token a connector's
  # sign-in holds (McpServer::Clio). Only the US region for now: Clio runs
  # each region on its own host (eu.app.clio.com, ca.app.clio.com), and an
  # account and its app live in one, so another region is another HOST.
  module Clio
    HOST = "https://app.clio.com".freeze
    API = "#{HOST}/api/v4".freeze
    TIMEOUT = 30 # seconds

    class Error < StandardError; end
    # The access token is no good: renew it.
    class Unauthorized < Error; end
    # Clio won't renew the sign-in, or there is nothing to renew it with: only a new sign-in helps.
    class GrantRefused < Unauthorized; end

    def self.host = URI(HOST).host

    # Where the person is sent to let the app in. Declining comes back to the
    # callback too (redirect_on_decline), as an error with the same state.
    def self.authorize_url(client_id:, redirect_uri:, state:)
      query = { response_type: "code", client_id: client_id, redirect_uri: redirect_uri, state: state, redirect_on_decline: "true" }
      "#{HOST}/oauth/authorize?#{URI.encode_www_form(query)}"
    end

    # The code from the callback, for an access token and a refresh token.
    def self.exchange(client, code:, redirect_uri:)
      token(grant_type: "authorization_code", code: code, redirect_uri: redirect_uri, **client)
    end

    # A fresh access token. Clio keeps the refresh token the same.
    def self.refresh(client, refresh_token)
      token(grant_type: "refresh_token", refresh_token: refresh_token, **client)
    end

    # Clio's status and error code, never what was sent: the form carries the secret.
    def self.token(form)
      response = Net::HTTP.post_form(URI("#{HOST}/oauth/token"), form.transform_keys(&:to_s))
      answer = JSON.parse(response.body.to_s) rescue {}
      answer = {} unless answer.is_a?(Hash)
      return answer if response.is_a?(Net::HTTPSuccess) && answer["access_token"].present?
      reason = "(#{response.code} #{answer['error']})".squish.sub(" )", ")")
      raise GrantRefused, "Clio refused the sign-in #{reason}" if response.code.to_i.in?([ 400, 401 ])
      raise Error, "Clio could not sign in #{reason}"
    rescue SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError, IOError => failure
      raise Error, "Could not reach Clio: #{failure.class.name.demodulize}"
    end

    # One call to API v4: JSON in and out. Clio's own message comes back on a
    # refusal, which tells the model what to fix.
    def self.request(token, method, path, query: {}, body: nil)
      uri = URI("#{API}/#{path}.json")
      uri.query = URI.encode_www_form(query.compact) if query.compact.any?
      request = Net::HTTP.const_get(method.to_s.capitalize).new(uri, "Authorization" => "Bearer #{token}", "Accept" => "application/json")
      if body
        request["Content-Type"] = "application/json"
        request.body = body.to_json
      end
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: TIMEOUT, read_timeout: TIMEOUT) { it.request(request) }
      raise Unauthorized, "Clio turned the token away" if response.is_a?(Net::HTTPUnauthorized)
      answer = (JSON.parse(response.body.to_s) rescue {}).then { it.is_a?(Hash) ? it : {} }
      raise Error, "Clio refused: #{refusal(answer) || "#{response.code} #{response.message}"}".truncate(500) unless response.is_a?(Net::HTTPSuccess)
      answer
    rescue SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError, IOError => failure
      raise Error, "Could not reach Clio: #{failure.class.name.demodulize}"
    end

    def self.refusal(answer)
      error = answer["error"]
      (error.is_a?(Hash) ? error["message"] : error).presence&.to_s
    end
    private_class_method :token, :refusal

    # The page_token of the next page Clio names, if there is one.
    def self.next_page_token(answer)
      url = answer.dig("meta", "paging", "next") or return
      URI.decode_www_form(URI(url).query.to_s).to_h["page_token"]
    rescue URI::InvalidURIError
      nil
    end
  end
end
