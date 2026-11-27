require "net/http"
require "json"
require "async/websocket/client"
require "async/http/endpoint"
require "async/barrier"

module DurableAssistants
  # OpenAI's Live call control for the voice pilot (docs/phone.md): accept or
  # reject one incoming SIP call by its session ID, and follow an accepted
  # one's events on its sideband. The API key goes only in the Authorization
  # header; an error names the HTTP status or what broke, never a body.
  module Live
    HOST = "api.openai.com".freeze
    TIMEOUT = 15 # seconds; an accept answers once the session is ready
    SESSION = /\A[A-Za-z0-9_-]{1,128}\z/
    # The connection was never made, so OpenAI saw nothing.
    NOT_SENT = [ Net::OpenTimeout, SocketError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, OpenSSL::SSL::SSLError ].freeze
    # The request may have reached OpenAI: whether it acted is unknown.
    MAYBE = [ Timeout::Error, SystemCallError, IOError, Net::HTTPBadResponse ].freeze

    # Our own bound on one call's listening: OpenAI's limit on a session is in
    # its session.started (expires_at), not published as a figure.
    LISTEN_LIMIT = 2.hours
    LOST = [ Async::WebSocket::ConnectionError, Protocol::WebSocket::Error, Async::TimeoutError, *NOT_SENT, *MAYBE ].freeze
    FIRST_ATTACH_WAIT = 0.25 # seconds; well within the sideband's replay window
    REFUSAL_CODES = %w[ invalid_api_key model_not_found rate_limit_exceeded session_not_found unknown_parameter ].freeze
    REFUSAL_LIMIT = 4.kilobytes

    class Error < StandardError; end
    class Unknown < Error; end

    def self.accept(key, session_id, model:, instructions:, delegation: nil)
      post(key, session_id, "accept", session: { type: "live", model:, instructions:, delegation: }.compact)
    end

    # 603 is Decline: this call won't be answered, here or elsewhere.
    def self.reject(key, session_id) = post(key, session_id, "reject", status_code: 603)

    # Keep one collector across sockets; accept is never repeated. Yield each
    # event with its own socket so answers never write to a closed connection.
    def self.attach(key, session_id, call_id: nil, &events)
      raise Error, "Not a Live session ID" unless SESSION.match?(session_id.to_s)
      # Use a WebSocket GET upgrade, not an extended CONNECT if TLS picks HTTP/2.
      endpoint = Async::HTTP::Endpoint.parse("wss://#{HOST}/v1/live/sessions/#{session_id}/attach",
        protocol: Async::HTTP::Protocol::HTTP11)
      Sync do |task|
        task.with_timeout(LISTEN_LIMIT.to_i) do
          closed = attach_once(endpoint, key, call_id, 1, &events)
          :reattached if !closed && attach_once(endpoint, key, call_id, 2, &events)
        end
      end
    end

    def self.attach_once(endpoint, key, call_id, attempt)
      stage = "connect"
      Async::WebSocket::Client.connect(endpoint, headers: [ [ "authorization", "Bearer #{key}" ] ]) do |connection|
        sideband = Sideband.new(connection, Async::Barrier.new)
        stage = "read"
        audit(call_id, attempt, "opened http=upgraded protocol=http/1.1")
        while (message = connection.read)
          event = parsed(message)
          next unless event.is_a?(Hash)
          yield event, sideband
          return true if event["type"] == "session.closed"
        end
      ensure
        sideband&.barrier&.stop
      end
      audit(call_id, attempt, "stage=read closed before session.closed")
      false
    rescue *LOST => problem
      response = problem.response if problem.is_a?(Async::WebSocket::ConnectionError)
      status = response&.status
      status = nil unless status.is_a?(Integer) && status.between?(100, 599)
      code = problem.code if problem.is_a?(Protocol::WebSocket::ClosedError)
      code = nil unless code.is_a?(Integer) && code.between?(1000, 4999)
      kind = problem.class.name.demodulize
      provider = " protocol=http/1.1 provider_code=#{refusal_code(response) || 'unknown'}" if status
      audit(call_id, attempt, "stage=#{stage} failed error=#{kind} http=#{status || 'unknown'} ws_close=#{code || 'unknown'}#{provider}")
      if attempt == 1 && (status == 400 || transient?(problem, status, code))
        Async::Task.current.sleep(FIRST_ATTACH_WAIT) if status == 400
        return false
      end

      http = "HTTP #{status}" if status
      close = "WebSocket #{code}" if code
      raise Error, "Lost the call's events (#{[ kind, http, close ].compact.join(', ')})", cause: nil
    end

    # The WebSocket client has already buffered a refused upgrade. Parse
    # only small JSON responses, and return a literal from our allowlist.
    def self.refusal_code(response)
      return unless (1..REFUSAL_LIMIT).cover?(response.body&.length)
      return unless Array(response.headers["content-type"]).first.to_s.split(";", 2).first == "application/json"

      data = JSON.parse(response.read, max_nesting: 8, allow_duplicate_key: false)
      return unless data.is_a?(Hash) && data["error"].is_a?(Hash)
      REFUSAL_CODES.find { |allowed| allowed == data["error"]["code"] }
    rescue JSON::ParserError
      nil
    end

    def self.transient?(problem, status, code)
      [ 404, 409, 425, 429 ].include?(status) || (500..599).cover?(status) ||
        [ 1001, 1011, 1012, 1013 ].include?(code) ||
        problem.is_a?(Errno::ECONNRESET) || problem.is_a?(EOFError) || problem.is_a?(Net::OpenTimeout)
    end

    def self.audit(call_id, attempt, detail)
      Rails.logger.info("Voice call #{call_id} sideband attempt=#{attempt} at=#{Time.now.utc.iso8601(3)} #{detail}") if call_id
    end

    private_class_method :attach_once, :refusal_code, :transient?, :audit

    # Takes a call's events back while it runs. Work that waits, as on the
    # agent's answer, runs beside the events, never holding them up, and stops
    # when the call does: no one is left to hear it.
    Sideband = Struct.new(:connection, :barrier) do
      def write(event)
        connection.write(Protocol::WebSocket::TextMessage.generate(event))
        connection.flush
      end

      def async(&) = barrier.async(&)
    end

    def self.parsed(message)
      JSON.parse(message.to_str)
    rescue JSON::ParserError
    end

    def self.post(key, session_id, action, body)
      raise Error, "Not a Live session ID" unless SESSION.match?(session_id.to_s)
      request = Net::HTTP::Post.new("/v1/live/sessions/#{session_id}/#{action}", "Authorization" => "Bearer #{key}", "Content-Type" => "application/json")
      request.body = body.to_json
      response = Net::HTTP.start(HOST, 443, use_ssl: true, open_timeout: TIMEOUT, read_timeout: TIMEOUT) { it.request(request) }
      return if response.is_a?(Net::HTTPSuccess)
      raise (response.is_a?(Net::HTTPClientError) ? Error : Unknown), "OpenAI answered HTTP #{response.code} to #{action}"
    rescue *NOT_SENT => problem
      raise Error, "Couldn't reach OpenAI to #{action} (#{problem.class.name.demodulize})"
    rescue *MAYBE => problem
      raise Unknown, "OpenAI didn't answer the #{action} (#{problem.class.name.demodulize})"
    end
  end
end
