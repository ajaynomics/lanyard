require "net/http"
require "json"
require "socket"
require "uri"
require "async/websocket/client"
require "async/http/endpoint"
require "io/endpoint/unix_endpoint"

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
        # Entries carry screenshots; the sidecar bounds a page at about 3 MB,
        # but always sends one entry, and a person's message may hold four 5 MB
        # pictures, base64.
        request("GET", "#{path(id)}/entries", access, { after: after, limit: limit }.compact, 32.megabytes)
      end

      # A new conversation holding this one's entries up to and including `at`.
      # `into` ({ workspaceId:, cwd: }) files it under another agent of the same
      # person: a new agent that starts from this thread.
      def fork(access, id, request_id:, at:, into: nil)
        request("POST", "#{path(id)}/forks", access, { requestId: request_id, at: at, into: into }.compact)
      end

      # A summary of the conversation so far, made while it goes on (/compact).
      def compact(access, id, request_id:, instructions: nil)
        request("POST", "#{path(id)}/compactions", access, { requestId: request_id, instructions: instructions }.compact)
      end

      # The conversation's whole history as pi's session file (JSONL), passed
      # to the block in chunks as the sidecar writes it. The title names the
      # session in pi; the sidecar does not keep one.
      def export(access, id, title:, &chunks)
        request("GET", "#{path(id)}/export", access, { title: title }, nil, 30, &chunks)
      end

      # A message waiting for the agent made a steer or a follow-up, or taken
      # back; each says whether it was still waiting ("changed", "withdrawn").
      def change_queued(access, id, queued_id, when_busy:)
        request("PATCH", "#{path(id)}/queued/#{escape(queued_id)}", access, whenBusy: when_busy)
      end

      def withdraw_queued(access, id, queued_id)
        request("DELETE", "#{path(id)}/queued/#{escape(queued_id)}", access)
      end

      def cancel(access, id, request_id)
        request("POST", "#{path(id)}/cancellations", access, requestId: request_id)
      end

      # The models the sidecar can run now and the thinking levels each
      # supports: pi-ai's catalogue, for the agent's settings (ModelCatalog).
      def models
        request("GET", "/v1/models", nil)
      end

      # A provider's owner console (Subscription, ApiKey): its subscription
      # and its API key, in one answer. Not about a person's conversation, so
      # no access scope. Each change names the version it saw; the sign-in
      # link comes back from start only.
      def subscription(provider)
        request("GET", subscription_path(provider), nil)
      end

      def start_subscription(provider, version)
        request("POST", "#{subscription_path(provider)}/start", nil, version: version)
      end

      # Exchanging the code with the provider can take up to 30 seconds.
      def finish_subscription(provider, version, id, code)
        request("POST", "#{subscription_path(provider)}/finish", nil, { version: version, id: id, code: code }, 1.megabyte, 40)
      end

      def disconnect_subscription(provider, version)
        request("POST", "#{subscription_path(provider)}/disconnect", nil, version: version)
      end

      # The owner's pasted API key (ApiKey): saving it (the sidecar checks it
      # with the provider first, up to 10 seconds) and removing it. Only its
      # last four characters ever come back.
      def save_api_key(provider, version, key)
        request("PUT", "#{subscription_path(provider)}/key", nil, { version: version, key: key }, 1.megabyte, 20)
      end

      def remove_api_key(provider, version)
        request("DELETE", "#{subscription_path(provider)}/key", nil, version: version)
      end

      # The SSH computers' public key, made on first use, for the person to add
      # to a machine's authorized_keys (docs/computers.md).
      def ssh_key(keyring:)
        request("GET", "/v1/computers/ssh/key", nil, { keyring: keyring })
      end

      # Whether a host's key is trusted, and its fingerprints: the trusted
      # ones, or what the host presents now. Reaching the host takes seconds.
      def ssh_host(host:, user:, keyring:)
        request("GET", "/v1/computers/ssh/host", nil, { host: host, user: user, keyring: keyring }, 1.megabyte, 70)
      end

      # Trusts the host's key, only if it still has the fingerprints the
      # person saw (409 when it does not).
      def trust_ssh_host(host:, user:, keyring:, fingerprints:)
        request("POST", "/v1/computers/ssh/host", nil, { host: host, user: user, keyring: keyring, fingerprints: fingerprints }, 1.megabyte, 70)
      end

      # One JSON-RPC message to a command connector, which the sidecar runs on
      # the conversation's computer (`computer`, as in the definition) from pi's
      # `entry`; the answer's `message` is the server's reply.
      def connector_message(access, id, name:, computer:, entry:, message:, read_timeout:)
        request("POST", "#{path(id)}/connectors/#{escape(name)}/rpc", access,
          { computer: computer, entry: entry, message: message }, 4.megabytes, read_timeout)
      end

      # Whether opening the conversation's screen would bring its computer back from
      # cold storage: {"waking" => "cold"} or {"waking" => nil}. A lookup;
      # nothing wakes. `computer` is the agent's Sprite name prefix.
      def computer(access, id, computer:)
        request("GET", "#{path(id)}/computer", access, computer: computer)
      end

      # Deletes the conversation's Sprite and its disk, for a deleted agent.
      # One already gone is fine.
      def remove_computer(access, id, computer:)
        request("DELETE", "#{path(id)}/computer", access, computer: computer)
      end

      # The agent's screen: a websocket to the sidecar, which wakes the
      # conversation's Sprite (up to two minutes) and pipes it to the screen's
      # websockify. `computer` is the agent's Sprite name prefix. Yields the
      # open connection; runs in the request's fiber under Falcon.
      def screen(access, id, computer:, &block)
        token, base, unix = transport
        query = URI.encode_www_form(actorId: access.actor_id, workspaceId: access.workspace_id, computer: computer)
        url = "#{unix ? "http://sidecar.local" : "#{base.scheme}://#{base.host}:#{base.port}"}#{path(id)}/screen?#{query}"
        endpoint = Async::HTTP::Endpoint.parse(url, (IO::Endpoint.unix(base.path) if unix))
        Async::WebSocket::Client.connect(endpoint, headers: [ [ "authorization", "Bearer #{token}" ] ], &block)
      rescue Async::WebSocket::ConnectionError, IOError, SystemCallError
        raise Error
      end

      private
        def path(id)
          "/v1/conversations/#{escape(id)}"
        end

        def subscription_path(provider)
          "/v1/subscriptions/#{escape(provider)}"
        end

        def escape(value)
          raise Error.new(422) unless value.is_a?(String) && value.match?(%r{\A[\w.:|+/=-]{1,512}\z})
          URI.encode_www_form_component(value)
        end

        # With a block, the answer's body is passed on in chunks as it arrives,
        # once its status says it is one; nothing is parsed or kept here.
        # The token, the sidecar's address and whether it is a Unix socket.
        def transport
          token = PiDurable.setting(:sidecar_token)
          raise Error unless token.is_a?(String) && token.length >= 16 && token != PiDurable.setting(:rails_token)

          base = URI(PiDurable.setting(:sidecar_url).to_s)
          unix = base.scheme == "unix"
          raise Error unless base.userinfo.nil? && base.query.nil? && base.fragment.nil?
          raise Error unless unix ? base.host.blank? && base.path.to_s.start_with?("/") && !base.path.end_with?("/") :
            %w[http https].include?(base.scheme) && base.host && [ "", "/" ].include?(base.path)
          [ token, base, unix ]
        rescue URI::InvalidURIError
          raise Error
        end

        def request(method, path, access, payload = {}, max_bytes = 1.megabyte, read_timeout = 10, &chunks)
          token, base, unix = transport

          uri = unix ? URI("http://sidecar.local") : base.dup
          uri.path = path
          data = access ? payload.merge(actorId: access.actor_id, workspaceId: access.workspace_id) : payload
          # A conversation's scope is read from the query, a DELETE's included.
          uri.query = URI.encode_www_form(data) if method == "GET" || (method == "DELETE" && access)
          message = Net::HTTPGenericRequest.new(method, method != "GET", true, uri.request_uri)
          message["Authorization"] = "Bearer #{token}"
          message["Accept"] = chunks ? "*/*" : "application/json"
          if method != "GET"
            message["Content-Type"] = "application/json"
            message.body = JSON.generate(data)
          end

          # Ignore ambient HTTP_PROXY; the destination is explicit app configuration.
          http = unix ? UnixHTTP.new(base.path) : Net::HTTP.new(uri.hostname, uri.port, nil)
          http.use_ssl = uri.scheme == "https" unless unix
          http.open_timeout = 2
          http.read_timeout = read_timeout
          http.write_timeout = 3
          return stream(http, message, &chunks) if chunks
          response = http.request(message)
          refuse_failure(response)
          raise Error.new(502) if response.body.to_s.bytesize > max_bytes
          result = JSON.parse(response.body)
          raise Error.new(502) unless result.is_a?(Hash)
          result
        rescue JSON::ParserError, URI::InvalidURIError, IOError, SystemCallError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError, Net::OpenTimeout
          raise Error
        end

        def stream(http, message)
          http.request(message) do |response|
            refuse_failure(response)
            response.read_body { yield it }
          end
          nil
        end

        def refuse_failure(response)
          status = response.code.to_i
          raise Error.new([ 400, 401, 403, 404, 409, 412, 422, 503 ].include?(status) ? status : 502, category_of(response)) unless status.between?(200, 299)
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
