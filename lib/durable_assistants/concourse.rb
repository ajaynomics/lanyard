require "net/http"
require "json"
require "uri"

module DurableAssistants
  # Concourse, the agents' mail network (docs/design/PARITY.md Round 5). This
  # file is the only code that speaks its HTTP, SSE and A2A. Every call is the
  # one the Pi connector makes today (concourse/pi/concourse-v3/src/client.ts,
  # auth.ts and doorbell.ts); when Concourse changes its wire, only this file
  # changes.
  module Concourse
    def self.setting(key) = DurableAssistants.config(:concourse, key)

    # One agent's machine client. No retries: a send or reply that got no answer
    # may still have happened, so the caller decides, never this class.
    class Client
      # Something went wrong, in words a person or a model can read. Never
      # carries a token, a secret or the peer's text.
      class Error < StandardError
        attr_reader :status

        def initialize(message, status: nil, uncertain: false)
          super(message)
          @status = status
          @uncertain = uncertain
        end

        # A send or reply that got no clear answer may have been delivered.
        def uncertain? = @uncertain
      end

      HANDLE = %r{\A[a-zA-Z0-9_-]{1,100}/[a-zA-Z0-9_-]{1,100}\z}
      PAGE_SIZE = 50
      MAX_BYTES = 4.megabytes
      TOKEN_LIFETIME = 1.hour # Ajent's machine tokens; never longer (machine-clients.md)
      RENEW_BEFORE = 1.minute
      DOORBELL_IDLE = 45 # seconds without a byte, keepalives included, before the stream counts as lost (doorbell.ts)
      DOORBELL_LIMIT = 15.minutes # the server's cap on one stream
      FRAME_LIMIT = 16.kilobytes
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
      # Capabilities come from here. Release line 3 means the doorbell
      # (`listen`), the paged inbox and the worker PATCH; nothing else is
      # advertised today.
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

      # Live mail: blocks until the server closes the stream, yielding :ready
      # once connected and :ping for each hint that mail may have arrived.
      # A hint carries no content; the caller sweeps the inbox.
      #
      # SLICE 5 GOES HERE (PARITY.md §29, not built). When `identity`
      # advertises the proposed /api/events stream (content, event ids,
      # Last-Event-ID, acks, ?after= polling), read it here instead of the
      # doorbell, and yield the events. Nothing outside this file changes
      # for the switch but what the block does with an event.
      def listen(session_id:, &hint)
        doorbell(session_id: session_id, &hint)
      end

      private
        # GET api/doorbell (Server-Sent Events): `ready`, then content-free
        # `ping`s and keepalive comments, until the server closes it.
        def doorbell(session_id:)
          raise Error, "That session name is not one Concourse accepts." unless session_id.match?(/\A[a-zA-Z0-9_-]{1,128}\z/)
          identity
          uri = URI("#{origin}/api/doorbell")
          get = Net::HTTP::Get.new(uri)
          get["Authorization"] = "Bearer #{token}"
          get["Accept"] = "text/event-stream"
          get["Concourse-Session-Id"] = session_id
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + DOORBELL_LIMIT
          connection(uri, read_timeout: DOORBELL_IDLE).request(get) do |response|
            check(response, writes: false)
            raise Error.new("Concourse's doorbell did not answer as a stream.", status: 502) unless response["Content-Type"].to_s.start_with?("text/event-stream")
            buffer, event, ready = +"", nil, false
            response.read_body do |chunk|
              buffer << chunk
              raise Error.new("Concourse's doorbell sent too much at once.", status: 502) if buffer.bytesize > FRAME_LIMIT
              while (line = buffer.slice!(/\A[^\n]*\n/))
                line = line.chomp
                if line.empty?
                  if event == "ready" && !ready
                    ready = true
                    yield :ready
                  elsif event == "ping" && ready
                    yield :ping
                  end
                  event = nil
                elsif line.start_with?("event:")
                  event = line.delete_prefix("event:").strip
                end
              end
              return if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            end
          end
          nil
        rescue Net::ReadTimeout
          nil # gone quiet: the caller connects again
        rescue IOError, SystemCallError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError => failure
          raise Error, "Lost Concourse's doorbell (#{failure.class.name.demodulize})."
        end

        def origin = Concourse.setting(:origin).to_s.delete_suffix("/")

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

        def request(method, path, body: nil, headers: {})
          uri = URI("#{origin}/#{path}")
          message = { get: Net::HTTP::Get, post: Net::HTTP::Post, patch: Net::HTTP::Patch }.fetch(method).new(uri)
          message["Authorization"] = "Bearer #{token}"
          message["Accept"] = "application/json"
          headers.each { |name, value| message[name] = value }
          if body
            message["Content-Type"] = "application/json"
            message.body = JSON.generate(body)
          end
          response = deliver(uri, message, writes: method != :get)
          check(response, writes: method != :get)
          parse(response)
        end

        def deliver(uri, message, writes: false)
          connection(uri).request(message)
        rescue IOError, SystemCallError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError => failure
          raise Error.new("Could not reach #{uri.host} (#{failure.class.name.demodulize}).#{" It may have been delivered." if writes}", uncertain: writes)
        end

        def connection(uri, read_timeout: 20)
          raise Error, "The Concourse address must start with https://." unless uri.is_a?(URI::HTTPS) || Rails.env.local?
          # Ignore ambient HTTP_PROXY; the destination is explicit configuration.
          http = Net::HTTP.new(uri.host, uri.port, nil)
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = 5
          http.read_timeout = read_timeout
          http.write_timeout = 10
          http
        end

        # A 4xx is a definite no; anything else after a write may have landed.
        def check(response, writes:)
          status = response.code.to_i
          return if status.between?(200, 299)
          forget_token if status == 401
          refused = status.between?(400, 499)
          words = { 401 => "Concourse did not accept the token", 403 => "Concourse refused this agent",
                    404 => "Concourse found no such task or agent", 429 => "Concourse is busy" }.fetch(status, "Concourse answered #{status}")
          raise Error.new("#{words}.#{" It may have been delivered." if writes && !refused}", status: status, uncertain: writes && !refused)
        end

        def forget_token
          Rails.cache.delete(token_key)
        end

        def parse(response)
          raise Error.new("Concourse's answer was too large.", status: 502) if response.body.to_s.bytesize > MAX_BYTES
          value = JSON.parse(response.body.to_s)
          raise Error.new("Concourse's answer was not understood.", status: 502) unless value.is_a?(Hash)
          value
        rescue JSON::ParserError
          raise Error.new("Concourse's answer was not understood.", status: 502)
        end

        def segment(value)
          raise Error.new("That id is not one Concourse uses.", status: 400) unless value.is_a?(String) && value.match?(/\A[\w.:-]{1,512}\z/)
          URI.encode_www_form_component(value)
        end
    end
  end
end
