require "net/http"

module DurableAssistants
  # One HTTPS request to an API, made with a key from the vault
  # (Tool::CallApiWithSavedKey, docs/passwords.md). The vault entry's address
  # is the only host it may reach, over https only, and its password is the
  # key, sent as a bearer token. The key goes from the vault to this request
  # and nowhere else: never to the agent's computer, the model, the ledger or
  # a log. Should the API echo it, the answer carries a placeholder instead.
  class KeyedRequest
    class Error < StandardError; end

    METHODS = %w[ GET POST PUT PATCH DELETE ].freeze
    # The vault entry sets these; the agent may not.
    RESERVED = %w[ authorization host cookie proxy-authorization content-length ].freeze
    TIMEOUT = 20 # seconds
    MAX_BODY = 40_000 # bytes of the answer the model reads

    def initialize(entry, method:, path:, query: nil, body: nil, headers: nil)
      @entry, @method, @path, @query, @body, @headers = entry, method.to_s.upcase, path.to_s, query, body, headers.to_h
    end

    def perform
      response = Net::HTTP.start(host, 443, use_ssl: true, open_timeout: TIMEOUT, read_timeout: TIMEOUT) { it.request(request) }
      { status: response.code.to_i, body: hidden(response.body.to_s.byteslice(0, MAX_BODY).scrub) }
    rescue Timeout::Error, SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse
      raise Error, "#{host} could not be reached."
    end

    private
      attr_reader :entry

      # The saved address with nothing but its host kept; a bare
      # "api.example.com" means its https site, as a saved sign-in's does.
      def host
        raise Error, "#{entry.name} has no https address saved with it, so it may reach no host." unless https? && entry.host
        entry.host
      end

      def https? = !entry.address.to_s.strip.match?(%r{\A[a-z][a-z0-9+.-]*://}i) || entry.address.to_s.strip.match?(%r{\Ahttps://}i)

      def request
        raise Error, "#{@method} is not a method it can send; use one of #{METHODS.to_sentence}." unless METHODS.include?(@method)
        raise Error, "The path must start with one /, as /v2/bookings does." unless @path.match?(%r{\A/(?!/)[^\s#]*\z})
        Net::HTTPGenericRequest.new(@method, @body.present?, true, target).tap do |request|
          @headers.each { |name, value| request[header(name)] = header_value(name, value) }
          request["Authorization"] = "Bearer #{key}"
          if @body.present?
            request["Content-Type"] = "application/json"
            request.body = @body.to_json
          end
        end
      end

      def target = @query.present? ? "#{@path}?#{URI.encode_www_form(@query.to_h)}" : @path

      def header(name)
        name = name.to_s
        raise Error, "#{name} is set from the vault entry, not by you." if RESERVED.include?(name.downcase)
        raise Error, "#{name} is not a header name." unless name.match?(/\A[A-Za-z0-9-]+\z/)
        name
      end

      # Net::HTTP raises on a line break; refusing first gives the model a reason.
      def header_value(name, value)
        value.to_s.tap { raise Error, "#{name}'s value can't contain a line break." if it.match?(/[\r\n]/) }
      end

      def key = entry.password.presence || raise(Error, "#{entry.name} has no key saved in its password.")

      def hidden(text) = entry.password.present? ? text.gsub(entry.password, "[the saved key]") : text
  end
end
