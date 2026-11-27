module DurableAssistants::Voipms
  class Error < StandardError
    UNKNOWN_STATUS = "unrecognised status".freeze
    VERIFY = "Check the current settings before trying again.".freeze

    TRANSPORT_DETAILS = {
      EOFError => "connection closed early",
      IOError => "network I/O failed",
      SocketError => "address or DNS lookup failed",
      Errno::ECONNRESET => "connection was reset",
      Errno::EPIPE => "connection pipe broke",
      Errno::ECONNREFUSED => "connection was refused",
      OpenSSL::SSL::SSLError => "TLS failed",
      Net::HTTPBadResponse => "invalid HTTP response",
      Net::HTTPHeaderSyntaxError => "invalid HTTP headers",
      Net::ProtocolError => "HTTP protocol error",
      Zlib::Error => "response decompression failed"
    }.transform_values(&:freeze).freeze
    private_constant :TRANSPORT_DETAILS

    attr_reader :reason, :status, :http_code, :source_class

    def initialize(message, reason: :validation, status: UNKNOWN_STATUS, http_code: nil, source_class: nil, outcome_unknown: false, transport_detail: nil)
      super(message)
      @reason, @status, @http_code, @source_class = reason, status, http_code, source_class
      @outcome_unknown, @transport_detail = outcome_unknown, transport_detail
    end

    def outcome_unknown? = @outcome_unknown

    # A readback can fail before it sends its own request. Do not turn that
    # into advice to retry, or a claim that the earlier text was not sent.
    def diagnostic
      case reason
      when :connect_timeout then "timed out opening the connection"
      when :write_timeout then "timed out sending the request"
      when :read_timeout then "timed out waiting for a response"
      when :request_timeout then "request timed out"
      when :refused, :unreadable_response, :server_error
        kind = { refused: "refused", unreadable_response: "unreadable response", server_error: "server error" }.fetch(reason)
        "#{kind} (#{[ ("HTTP #{http_code}" if http_code), status ].compact.join('; ')})"
      when :credential_origin, :credentials_missing, :credentials_unavailable then "could not use the configured sign-in"
      else @transport_detail ? "#{@transport_detail} (#{UNKNOWN_STATUS})" : UNKNOWN_STATUS
      end
    end

    CHECK_BEFORE_RESEND = "Check voip.ms's message log before any manual resend.".freeze

    def self.server_failure(code)
      http_code = Integer(code, 10)
      new("voip.ms returned HTTP #{http_code}. The send failed. #{CHECK_BEFORE_RESEND}", reason: :server_error, http_code: http_code)
    end

    # A status is named when it is a known refusal, or is shaped like one and
    # shares nothing with the credentials sent; the rest of the reply never is.
    def self.response(code, status:, json:, outcome_unknown: false, credentials: [])
      http_code = Integer(code, 10, exception: false)
      http_code = nil unless http_code&.between?(100, 599)
      http = http_code ? "HTTP #{http_code}; " : ""
      status = UNKNOWN_STATUS unless status.is_a?(String) && status.ascii_only? && status.match?(/\A[a-z_]{1,40}\z/) &&
        (KNOWN_REFUSAL_STATUSES.include?(status) || unlike_credentials?(status, credentials))

      if json
        new("voip.ms refused the request (#{http}#{status})", reason: :refused, status: status, http_code: http_code)
      else
        new("voip.ms returned an unreadable response (#{http}#{UNKNOWN_STATUS}). #{VERIFY}", reason: :unreadable_response,
          http_code: http_code, outcome_unknown: outcome_unknown)
      end
    end

    # Compared by letters alone, so an echo with its punctuation changed still matches.
    def self.unlike_credentials?(status, credentials)
      letters = ->(text) { text.to_s.downcase.delete("^a-z") }
      credentials.map(&letters).compact_blank.none? { letters[status].include?(it) || it.include?(letters[status]) }
    end
    private_class_method :unlike_credentials?

    def self.transport(problem, attempted:)
      attempted = false if problem.is_a?(Net::OpenTimeout)
      reason, message = if problem.is_a?(Timeout::Error) || problem.is_a?(Errno::ETIMEDOUT)
        if !attempted
          [ :connect_timeout, "voip.ms timed out opening the connection; the request was not sent." ]
        elsif problem.is_a?(Net::WriteTimeout)
          [ :write_timeout, "voip.ms timed out sending the request. #{VERIFY}" ]
        elsif problem.is_a?(Net::ReadTimeout)
          [ :read_timeout, "voip.ms timed out waiting for a response. #{VERIFY}" ]
        else
          [ :request_timeout, "The request to voip.ms timed out. #{VERIFY}" ]
        end
      else
        detail = TRANSPORT_DETAILS.find { |type, _| problem.is_a?(type) }&.last
        label = [ detail, UNKNOWN_STATUS ].compact.join("; ")
        if attempted
          [ :uncertain_transport, "Could not complete the request to voip.ms (#{label}). #{VERIFY}" ]
        else
          [ :connection_failed, "Could not reach voip.ms (#{label}); the request was not sent." ]
        end
      end

      # Retain the type for diagnosis, never the exception: a socket or vault
      # failure can put provider data in its message or exception chain.
      new(message, reason: reason, source_class: problem.class, outcome_unknown: attempted, transport_detail: detail)
    end
  end
end
