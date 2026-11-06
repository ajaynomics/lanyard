require "net/http"
require "json"
require "socket"
require "uri"

module DurableAssistants
  module PiDurable
    def self.setting(key)
      DurableAssistants.config(:pi_durable, key)
    end

    # HTTP over a Unix socket: production reaches the sidecar through
    # bin/agent-container's socket on the shared storage volume, so the
    # sidecar has no network listener at all (docs/agent.md).
    class UnixHTTP < Net::HTTP
      def initialize(socket_path, _port = nil)
        super("sidecar.local", 80)
        @socket_path = socket_path
      end

      # Never an ambient HTTP proxy: the socket is the destination.
      def proxy?
        false
      end

      private
        def connect
          io = Timeout.timeout(open_timeout, Net::OpenTimeout) { UNIXSocket.new(@socket_path) }
          @socket = Net::BufferedIO.new(io, read_timeout: read_timeout, write_timeout: write_timeout,
            continue_timeout: continue_timeout, debug_output: @debug_output)
          on_connect
        end
    end

    # No retries: a failed response does not prove that admission failed.
    class Client
      class Error < StandardError
        # The sidecar's fixed reason category (`model_unavailable`), when it gave one.
        attr_reader :status, :category

        def initialize(status = 503, category = nil)
          @status = status
          @category = category
          super("agent_unavailable")
        end
      end

      def conversation(access, request_id)
        request("POST", "/v1/conversations", access, requestId: request_id)
      end

      def snapshot(access, id)
        request("GET", path(id), access)
      end

      def submit(access, id, request_id:, content:, when_busy:, definition:)
        request("POST", "#{path(id)}/submissions", access,
          requestId: request_id, content: content, whenBusy: when_busy, definition: definition)
      end

      # A doorbell for one waiting tool call; it carries no decision.
      def wake(access, id, key)
        request("POST", "#{path(id)}/wakes", access, key: key)
      end

      # Committed transcript entries after an entry id, oldest first.
      def entries(access, id, after: nil, limit: 200)
        request("GET", "#{path(id)}/entries", access, **{ after: after, limit: limit }.compact)
      end

      def cancel(access, id, request_id)
        request("POST", "#{path(id)}/cancellations", access, requestId: request_id)
      end

      private
        def path(id)
          "/v1/conversations/#{escape(id)}"
        end

        def escape(value)
          raise Error.new(422) unless value.is_a?(String) && value.match?(%r{\A[\w.:|+/=-]{1,512}\z})
          URI.encode_www_form_component(value)
        end

        def request(method, path, access, payload = {})
          token = PiDurable.setting(:sidecar_token)
          raise Error unless token.is_a?(String) && token.length >= 16 && token != PiDurable.setting(:rails_token)

          base = URI(PiDurable.setting(:sidecar_url).to_s)
          unix = base.scheme == "unix"
          raise Error unless base.userinfo.nil? && base.query.nil? && base.fragment.nil?
          raise Error unless unix ? base.host.blank? && base.path.to_s.start_with?("/") && !base.path.end_with?("/") :
            %w[http https].include?(base.scheme) && base.host && [ "", "/" ].include?(base.path)

          uri = unix ? URI("http://sidecar.local") : base.dup
          uri.path = path
          data = payload.merge(actorId: access.actor_id, workspaceId: access.workspace_id)
          uri.query = URI.encode_www_form(data) if method == "GET"
          message = Net::HTTPGenericRequest.new(method, method != "GET", true, uri.request_uri)
          message["Authorization"] = "Bearer #{token}"
          message["Accept"] = "application/json"
          if method != "GET"
            message["Content-Type"] = "application/json"
            message.body = JSON.generate(data)
          end

          # Ignore ambient HTTP_PROXY; the destination is explicit app configuration.
          http = unix ? UnixHTTP.new(base.path) : Net::HTTP.new(uri.hostname, uri.port, nil)
          http.use_ssl = uri.scheme == "https" unless unix
          http.open_timeout = 2
          http.read_timeout = 10
          http.write_timeout = 3
          response = http.request(message)
          status = response.code.to_i
          raise Error.new([ 400, 401, 403, 404, 409, 422, 503 ].include?(status) ? status : 502, category_of(response)) unless status.between?(200, 299)
          raise Error.new(502) if response.body.to_s.bytesize > 1_048_576
          result = JSON.parse(response.body)
          raise Error.new(502) unless result.is_a?(Hash)
          result
        rescue JSON::ParserError, URI::InvalidURIError, IOError, SystemCallError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError, Net::OpenTimeout
          raise Error
        end

        def category_of(response)
          category = JSON.parse(response.body.to_s)["error"] if response.body.to_s.bytesize <= 4_096
          category if category.is_a?(String) && category.match?(/\A[a-z_]{1,64}\z/)
        rescue JSON::ParserError
          nil
        end
    end
  end
end
