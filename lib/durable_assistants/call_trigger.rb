require "net/http"

module DurableAssistants
  # The voice gateway's call trigger (docs/phone.md): one POST of the number's
  # digits as JSON ({"number":"442071838750"}), with a bearer token in the
  # Authorization header. Its URL is a private address the
  # operator sets (VOICE__CALL_TRIGGER_URL), so it is not checked as a
  # connector's is (McpServer::Address), which would refuse it. Never retried:
  # a second POST could ring the phone again.
  module CallTrigger
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 45 # seconds; the gateway answers once the carrier does, or gives up
    # The connection was never made, so nothing rang.
    NOT_SENT = [ Net::OpenTimeout, SocketError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH ].freeze
    # The request may have reached the gateway: whether it rang is unknown.
    MAYBE = [ Timeout::Error, SystemCallError, IOError, Net::HTTPBadResponse ].freeze

    class NotSent < StandardError; end
    class Unknown < StandardError; end

    # The gateway's status, as an Integer; NotSent or Unknown, naming the
    # error's class, never a body.
    def self.ring(url, token, number)
      uri = URI(url)
      request = Net::HTTP::Post.new(uri, "Authorization" => "Bearer #{token}", "Content-Type" => "application/json")
      request.body = { number: number }.to_json
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
        open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT, max_retries: 0) { it.request(request) }.code.to_i
    rescue *NOT_SENT => problem
      raise NotSent, problem.class.name.demodulize
    rescue *MAYBE => problem
      raise Unknown, problem.class.name.demodulize
    end
  end
end
