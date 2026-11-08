require "net/http"
require "json"
require "uri"

module DurableAssistants
  # Concourse, the agents' mail network (docs/design/PARITY.md Round 5). This
  # file is the only code that speaks its HTTP and A2A. Its calls are the Pi
  # connector's (concourse/pi/concourse-v3/src/client.ts and auth.ts), and the
  # event log's (concourse docs/events-api.md); when Concourse changes its
  # wire, only this file changes.
  module Concourse
    def self.setting(key) = DurableAssistants.config(:concourse, key)

    # An install without a network of its own has none: no agent is offered
    # it, and a client says so rather than calling anywhere.
    def self.configured? = setting(:origin).present? && setting(:token_url).present?

    def self.origin = setting(:origin).to_s.delete_suffix("/")

    # The plumbing every call shares: one connection to an address from
    # configuration, and an answer read as a JSON object.
    module Wire
      module_function

      def deliver(uri, message, writes: false, read_timeout: 20)
        connection(uri, read_timeout: read_timeout).request(message)
      rescue IOError, SystemCallError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError => failure
        raise Client::Error.new("Could not reach #{uri.host} (#{failure.class.name.demodulize}).#{" It may have been delivered." if writes}", uncertain: writes)
      end

      def connection(uri, read_timeout: 20)
        raise Client::Error, "The Concourse address must start with https://." unless uri.is_a?(URI::HTTPS) || Rails.env.local?
        # Ignore ambient HTTP_PROXY; the destination is explicit configuration.
        http = Net::HTTP.new(uri.host, uri.port, nil)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = 5
        http.read_timeout = read_timeout
        http.write_timeout = 10
        http
      end

      def parse(response)
        raise Client::Error.new("Concourse's answer was too large.", status: 502) if response.body.to_s.bytesize > Client::MAX_BYTES
        value = JSON.parse(response.body.to_s)
        raise Client::Error.new("Concourse's answer was not understood.", status: 502) unless value.is_a?(Hash)
        value
      rescue JSON::ParserError
        raise Client::Error.new("Concourse's answer was not understood.", status: 502)
      end

      # The one-word reason in an error's body (`not_a_member`, `declined`,
      # `invalid_grant`), and never more of it: the words are the server's.
      def reason(response)
        body = parse(response)
        [ body["reason"], body["error"] ].find { it.is_a?(String) && it.match?(/\A[a-z_]{1,64}\z/) }
      rescue Client::Error
        nil
      end
    end

    # One agent's machine client. No retries: a send or reply that got no answer
    # may still have happened, so the caller decides, never this class.
    class Client
      include Wire

      # Something went wrong, in words a person or a model can read. Never
      # carries a token, a secret or the peer's text. `reason` is the server's
      # one-word reason, when it gave one.
      class Error < StandardError
        attr_reader :status, :reason

        def initialize(message, status: nil, uncertain: false, reason: nil)
          super(message)
          @status = status
          @uncertain = uncertain
          @reason = reason
        end

        # A send or reply that got no clear answer may have been delivered.
        def uncertain? = @uncertain
      end

      HANDLE = %r{\A[a-zA-Z0-9_-]{1,100}/[a-zA-Z0-9_-]{1,100}\z}
      PAGE_SIZE = 50
      MAX_BYTES = 4.megabytes
      TOKEN_LIFETIME = 1.hour # Ajent's machine tokens; never longer (machine-clients.md)
      RENEW_BEFORE = 1.minute
      EVENTS_WAIT = 25 # seconds: the longest Concourse holds a poll open
      REPLY_STATES = %w[ TASK_STATE_COMPLETED TASK_STATE_FAILED TASK_STATE_REJECTED TASK_STATE_INPUT_REQUIRED TASK_STATE_WORKING ].freeze

      attr_reader :organization, :handle

      def initialize(organization:, handle:, client_id:, client_secret:)
        @organization, @handle, @client_id, @client_secret = organization.to_s, handle.to_s, client_id.to_s, client_secret.to_s
        raise Error, "The handle must look like acme/assistant." unless @handle.match?(HANDLE)
        raise Error, "The organization must look like acme." unless @organization.match?(/\A[a-zA-Z0-9_-]{1,100}\z/)
      end

      # GET api/identity: who these credentials are on Concourse, read once
      # per client. Refused unless it is the organization, handle and client
      # entered, on release line 3, the only one this file speaks.
      #
      # Release line 3 means the event log, the paged inbox and the worker
      # PATCH.
      def identity
        @identity ||= begin
          found = request(:get, "api/identity")
          prefix, name = handle.split("/")
          unless found["release_line"] == 3 && found["agent_id"].is_a?(Integer)
            raise Error.new("Concourse answered with an identity this app does not understand.", status: 200)
          end
          address = "#{found["prefix"] || found["owner"]}/#{found["handle"]} in #{found["organization"]}"
          unless found["organization"] == organization && found["handle"] == name && [ found["prefix"], found["owner"] ].include?(prefix) &&
              found["oauth_client_id"] == @client_id
            raise Error.new("These credentials belong to #{address} on Concourse, not #{handle} in #{organization}.", status: 200)
          end
          found
        end
      end

      # Where this agent stands on Concourse, from GET api/identity (the join
      # contract, F): "admitted"; "awaiting_approval" or "declined" by an
      # owner of its organization; or "disconnected", when Concourse or Ajent
      # no longer accepts its credentials. Anything else is an Error. A 401
      # is asked once more with a new token, so a stale one in the cache is
      # not taken for a retired agent.
      def standing(retried: false)
        identity
        "admitted"
      rescue Error => problem
        if problem.status == 403 && problem.reason.in?(%w[ awaiting_approval declined ]) then problem.reason
        elsif problem.status == 401 then retried ? "disconnected" : standing(retried: true)
        else raise
        end
      end

      # POST connect/revoke (the join contract, G): retires this agent on
      # Concourse, so its address stops and joining again makes a new one.
      # 204 is done, and so is 401, which is how a repeat is answered; so is
      # Ajent refusing the machine client, which then can do nothing anywhere.
      # Anything else leaves the agent as it was.
      def revoke
        raise Error, "Concourse is not set up on this install." unless Concourse.configured?
        uri = URI("#{origin}/connect/revoke")
        post = Net::HTTP::Post.new(uri)
        post["Authorization"] = "Bearer #{token}"
        response = deliver(uri, post, writes: true)
        return forget_token if %w[ 204 401 ].include?(response.code)
        raise Error.new("Concourse did not take #{handle} off; it answered #{response.code}.", status: response.code.to_i)
      rescue Error => problem
        raise unless problem.status == 401
      end

      # GET agents?query=: the organization's directory, as `concourse_find`
      # in the Pi connector reads it.
      def find(query = nil)
        identity
        request(:get, "agents#{"?#{URI.encode_www_form(query: query)}" if query.present?}").fetch("agents", [])
      end

      # GET api/tasks/:id: one task this agent can see, sent or received.
      def task(id)
        identity
        found = request(:get, "api/tasks/#{segment(id)}")
        raise Error.new("Concourse sent another task.", status: 200) unless found["id"] == id
        found
      end

      # GET agents/:agent_id/tasks: unfinished tasks addressed to this agent,
      # newest first, a page at a time. `page_token` continues further back.
      def inbox(page_token = nil)
        query = URI.encode_www_form({ pageSize: PAGE_SIZE, pageToken: page_token.presence }.compact)
        page = request(:get, "agents/#{identity.fetch("agent_id")}/tasks?#{query}")
        unless page["tasks"].is_a?(Array) && page["nextPageToken"].is_a?(String)
          raise Error.new("Concourse answered the inbox in a shape this app does not understand.", status: 200)
        end
        page
      end

      # A2A v1.0 JSON-RPC SendMessage, returning at once, to
      # /a2a/<organization>/<prefix>/<agent>. Concourse keeps the first send
      # of a messageId, so sending the same id again cannot deliver twice.
      # Answers the task (or, rarely, a direct message) Concourse returns.
      def send_message(recipient, message_id:, text:, task_id: nil, context_id: nil)
        raise Error.new("Address the agent as prefix/agent, like acme/assistant.", status: 400) unless recipient.to_s.match?(HANDLE)
        identity
        message = { messageId: message_id, role: "ROLE_USER", parts: [ { text: text } ], taskId: task_id.presence, contextId: context_id.presence }.compact
        body = { jsonrpc: "2.0", id: message_id, method: "SendMessage",
                 params: { message: message, configuration: { returnImmediately: true, historyLength: 0, acceptedOutputModes: %w[ text/plain application/json ] } } }
        answer = request(:post, "a2a/#{segment(organization)}/#{recipient.split("/").map { segment(it) }.join("/")}", body: body, headers: { "A2A-Version" => "1.0" })
        if answer["error"].is_a?(Hash)
          raise Error.new("Concourse refused the message: #{answer.dig("error", "message").to_s.truncate(200).presence || "no reason given"}.", status: 400)
        end
        answer.dig("result", "task") || answer.dig("result", "message") or
          raise Error.new("Concourse's answer to the send was not understood; it may have been delivered.", uncertain: true)
      end

      # PATCH tasks/:id: this agent's answer on a task addressed to it, with
      # an explicit state. Answers the task as it now stands.
      def reply(task_id, state:, text: nil)
        raise Error.new("#{state} is not a state a reply can set.", status: 400) unless REPLY_STATES.include?(state)
        identity
        body = { state: state, message: ({ parts: [ { text: text } ] } if text.present?) }.compact
        found = request(:patch, "tasks/#{segment(task_id)}", body: body)
        raise Error.new("Concourse answered for another task; the reply may have been recorded.", uncertain: true) unless found["id"] == task_id
        found
      end

      # GET api/events: what peers did since the server's cursor (or `after`),
      # waiting up to `wait` seconds for something to happen. Reading never
      # acknowledges; `acknowledge` does, after the events are handled. The
      # log can miss events across a Concourse deploy and keeps 30 days, so it
      # makes mail sooner and the inbox sweep stays (docs/events-api.md).
      def events(after: nil, wait: EVENTS_WAIT, limit: 100)
        identity
        query = URI.encode_www_form({ after: after, limit: limit, wait: wait }.compact)
        page = request(:get, "api/events?#{query}", read_timeout: wait + 15)
        unless page["events"].is_a?(Array) && page["cursor"].is_a?(Integer) && page["oldest"].is_a?(Integer)
          raise Error.new("Concourse answered the events in a shape this app does not understand.", status: 200)
        end
        page
      end

      # PUT api/push_config: Concourse posts a notice to `url`, with `token`
      # in X-A2A-Notification-Token, for each new event. Replaces any earlier
      # one, so sending it again rotates the token.
      def push_to(url, token:)
        identity
        request(:put, "api/push_config", body: { url: url, token: token })
      end

      # DELETE api/push_config: no more notices.
      def stop_pushing
        identity
        request(:delete, "api/push_config")
      end

      # PUT api/events/cursor: everything up to `cursor` is handled.
      # Cumulative and idempotent, so sending it twice is harmless.
      def acknowledge(cursor)
        identity
        request(:put, "api/events/cursor", body: { cursor: cursor })
      end

      private
        def origin = Concourse.origin

        # Ajent's client_credentials grant, kept in Rails.cache until a minute
        # before it expires. The key covers the secret, so a new secret never
        # reuses an old token.
        def token
          Rails.cache.read(token_key) || grant(token_key)
        end

        def token_key
          "concourse/token/#{Digest::SHA256.hexdigest([ origin, Concourse.setting(:token_url), @client_id, @client_secret ].join("\n"))}"
        end

        def grant(key)
          uri = URI(Concourse.setting(:token_url).to_s)
          raise Error, "The Ajent token address must start with https://." unless uri.is_a?(URI::HTTPS) || Rails.env.local?
          post = Net::HTTP::Post.new(uri)
          post["Accept"] = "application/json"
          # RFC 6749 §2.3.1: each half form-encoded, as the Pi connector does.
          post["Authorization"] = "Basic #{Base64.strict_encode64("#{URI.encode_www_form_component(@client_id)}:#{URI.encode_www_form_component(@client_secret)}")}"
          post.set_form_data(grant_type: "client_credentials", scope: "concourse", resource: origin)
          response = deliver(uri, post)
          raise Error.new("Ajent refused the client id and secret.", status: response.code.to_i) unless response.is_a?(Net::HTTPSuccess)
          grant = parse(response)
          lifetime = grant["expires_in"]
          unless grant["access_token"].is_a?(String) && grant["access_token"].match?(/\A[A-Za-z0-9._~+\/-]+=*\z/) && grant["token_type"].to_s.casecmp?("bearer") &&
              lifetime.is_a?(Integer) && lifetime.between?(1, TOKEN_LIFETIME.to_i) && (grant["scope"].nil? || grant["scope"] == "concourse")
            raise Error, "Ajent answered with a token this app does not accept."
          end
          Rails.cache.write(key, grant["access_token"], expires_in: [ lifetime - RENEW_BEFORE.to_i, 1 ].max)
          grant["access_token"]
        end

        def request(method, path, body: nil, headers: {}, read_timeout: 20)
          raise Error, "Concourse is not set up on this install." unless Concourse.configured?
          uri = URI("#{origin}/#{path}")
          message = { get: Net::HTTP::Get, post: Net::HTTP::Post, patch: Net::HTTP::Patch, put: Net::HTTP::Put, delete: Net::HTTP::Delete }.fetch(method).new(uri)
          message["Authorization"] = "Bearer #{token}"
          message["Accept"] = "application/json"
          headers.each { |name, value| message[name] = value }
          if body
            message["Content-Type"] = "application/json"
            message.body = JSON.generate(body)
          end
          response = deliver(uri, message, writes: method != :get, read_timeout: read_timeout)
          check(response, writes: method != :get)
          response.is_a?(Net::HTTPNoContent) ? {} : parse(response)
        end

        # A 4xx is a definite no; anything else after a write may have landed.
        def check(response, writes:)
          status = response.code.to_i
          return if status.between?(200, 299)
          forget_token if status == 401
          refused = status.between?(400, 499)
          words = { 401 => "Concourse did not accept the token", 403 => "Concourse refused this agent",
                    404 => "Concourse found no such task or agent", 410 => "Concourse no longer keeps those events", 429 => "Concourse is busy" }.fetch(status, "Concourse answered #{status}")
          raise Error.new("#{words}.#{" It may have been delivered." if writes && !refused}", status: status, uncertain: writes && !refused,
            reason: (Wire.reason(response) if refused))
        end

        def forget_token
          Rails.cache.delete(token_key)
        end

        def segment(value)
          raise Error.new("That id is not one Concourse uses.", status: 400) unless value.is_a?(String) && value.match?(/\A[\w.:-]{1,512}\z/)
          URI.encode_www_form_component(value)
        end
    end

    # Joining in one click, by the contract agreed with Concourse (docs/design.md,
    # "Joining Concourse"): the person's browser goes to /connect, where they
    # sign in, pick an organization and approve; it comes back with a one-time
    # code, which this redeems, with the PKCE verifier, for the agent's own
    # machine client.
    module Connect
      STATUSES = %w[ admitted awaiting_approval ].freeze

      # GET /connect, the page the person's browser goes to.
      def self.authorize_url(redirect_uri:, state:, code_challenge:, handle:, name:)
        query = { response_type: "code", redirect_uri: redirect_uri, state: state, code_challenge: code_challenge, code_challenge_method: "S256",
                  handle: handle, name: name, app_name: DurableAssistants.config(:app, :name) }
        "#{Concourse.origin}/connect?#{URI.encode_www_form(query)}"
      end

      # POST /connect/token: the agent Concourse made, and its machine client.
      # A code works once, within ten minutes.
      def self.redeem(code:, redirect_uri:, code_verifier:)
        raise Client::Error, "Concourse is not set up on this install." unless Concourse.configured?
        uri = URI("#{Concourse.origin}/connect/token")
        post = Net::HTTP::Post.new(uri)
        post["Accept"] = "application/json"
        post.set_form_data(grant_type: "authorization_code", code: code, redirect_uri: redirect_uri, code_verifier: code_verifier)
        response = Wire.deliver(uri, post)
        unless response.is_a?(Net::HTTPSuccess)
          reason = Wire.reason(response)
          raise Client::Error.new("Concourse refused the join#{" (#{reason})" if reason}. Start again.", status: response.code.to_i, reason: reason)
        end
        grant = Wire.parse(response)
        agent = grant["agent"]
        unless agent.is_a?(Hash) && agent["address"].to_s.match?(Client::HANDLE) && agent["address"].split("/").last == agent["handle"] &&
            agent["organization"].to_s.match?(/\A[a-zA-Z0-9_-]{1,100}\z/) && STATUSES.include?(agent["status"]) &&
            [ grant["client_id"], grant["client_secret"] ].all? { it.is_a?(String) && it.present? }
          raise Client::Error.new("Concourse answered the join in a shape this app does not understand.", status: 200)
        end
        # The agent's secret goes to this token server every hour. Another
        # than the install's own is a Concourse misconfigured, or one not to
        # be trusted with where its secrets go, so the join stops here.
        unless grant["token_endpoint"] == Concourse.setting(:token_url)
          raise Client::Error.new("Concourse named another token server than this install's, so #{agent["address"]} was not saved.", status: 200)
        end
        grant
      end
    end
  end
end
