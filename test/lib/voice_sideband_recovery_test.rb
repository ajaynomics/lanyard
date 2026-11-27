require "test_helper"
require "async/http/server"
require "async/websocket/adapters/http"

class VoiceSidebandRecoveryTest < ActiveSupport::TestCase
  test "a transient handshake failure attaches again without losing the session" do
    script = [ 503, [ said("Hello", "first"), closed ] ]
    output = StringIO.new
    events, requests = with_logger(output) { listen(*script) }

    assert_match(/Voice call 4 sideband attempt=1 at=\S+ stage=connect failed error=ConnectionError http=503/, output.string)
    assert_match(/Voice call 4 sideband attempt=2 at=\S+ opened http=upgraded/, output.string)
    assert_no_match(/private response body|private response header|synthetic-key|live_fixture|Hello/, output.string)

    assert_equal [ said("Hello", "first"), closed ], events
    assert_equal [ "live_fixture", "live_fixture" ], requests
  end

  test "a dropped stream keeps the first words and ignores replayed deltas on reattach" do
    first = said("Hello ", "first")
    events, requests, outcome = listen([ first ], [ first, said("again", "second"), closed ])
    transcript = Agent::VoiceCall::Transcript.new
    events.each { transcript << it }

    assert_equal "Caller: Hello again", transcript.lines("Assistant")
    assert_equal "remote_hangup", transcript.closed
    assert_equal 2, requests.size
    assert_equal :reattached, outcome
  end

  test "an abnormal close reports the read stage and its code and keeps the words across one reattach" do
    first = said("Hello ", "first")
    drop = ->(socket) do
      socket.write(first.to_json)
      socket.flush
      socket.close(1011, "private close reason")
    end
    output = StringIO.new
    events, requests, outcome = with_logger(output) { listen(drop, [ first, said("again", "second"), closed ]) }
    transcript = Agent::VoiceCall::Transcript.new
    events.each { transcript << it }

    assert_match(/stage=read failed error=ClosedError http=unknown ws_close=1011/, output.string)
    assert_no_match(/private close reason|Hello|synthetic-key|live_fixture/, output.string)
    assert_equal "Caller: Hello again", transcript.lines("Assistant")
    assert_equal :reattached, outcome
    assert_equal 2, requests.size
  end

  test "a forbidden handshake is not retried and reports only the HTTP status" do
    requests = []
    failure = assert_raises(DurableAssistants::Live::Error) { listen(403, requests:) }

    assert_equal [ "live_fixture" ], requests
    assert_equal "Lost the call's events (ConnectionError, HTTP 403)", failure.message
  end

  test "one 400 on the first attach waits briefly then reads the same call on an upgrade" do
    output = StringIO.new
    first = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    events, requests, outcome = with_logger(output) { listen(refused("unknown_parameter"), [ said("Hello", "first"), closed ]) }

    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - first, :>=, 0.2
    assert_equal [ "live_fixture", "live_fixture" ], requests
    assert_equal [ said("Hello", "first"), closed ], events
    assert_equal :reattached, outcome
    assert_match(/attempt=1 at=\S+ stage=connect failed error=ConnectionError http=400 .*provider_code=unknown_parameter/, output.string)
    assert_match(/attempt=2 at=\S+ opened http=upgraded/, output.string)
    assert_no_match(/private detail|synthetic-key|live_fixture|Hello/, output.string)
  end

  test "a second 400 stops; an unknown code and a refusal body stay private" do
    requests, output = [], StringIO.new
    failure = with_logger(output) do
      assert_raises(DurableAssistants::Live::Error) { listen(refused("unknown_parameter"), refused("private_detail"), requests:) }
    end

    assert_equal [ "live_fixture", "live_fixture" ], requests
    assert_equal "Lost the call's events (ConnectionError, HTTP 400)", failure.message
    assert_nil failure.cause
    assert_match(/attempt=2 at=\S+ stage=connect failed error=ConnectionError http=400 .*provider_code=unknown$/, output.string)
    assert_no_match(/private.detail|synthetic-key|live_fixture/, output.string)
  end

  test "a TLS listener that prefers HTTP/2 sees an HTTP/1.1 upgrade at the same Live session path" do
    events, requests = listen([ said("Hello", "first"), closed ], tls: true)

    assert_equal [ said("Hello", "first"), closed ], events
    assert_equal [ "v1/live/sessions/live_fixture/attach" ], requests
  end

  test "two transient refusals stop after the second attempt" do
    requests = []
    failure = assert_raises(DurableAssistants::Live::Error) { listen(503, 503, requests:) }
    assert_equal 2, requests.size
    assert_match(/HTTP 503/, failure.message)
  end

  private
    def with_logger(output)
      original = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(output)
      yield
    ensure
      Rails.logger = original
    end

    def said(words, id) = { "type" => "session.input_transcript.delta", "delta" => words, "event_id" => id }
    def closed = { "type" => "session.closed", "reason" => "remote_hangup" }

    def refused(code)
      body = { error: { code:, message: "private detail: synthetic-key live_fixture" } }.to_json
      Protocol::HTTP::Response[400, { "content-type" => "application/json" }, [ body ]]
    end

    # Redirect only the destination. The HTTP refusal and WebSocket frames go
    # through the real client so this checks the pinned gem's failure mode.
    def listen(*script, requests: [], tls: false)
      connect = Async::WebSocket::Client.method(:connect)
      TCPServer.open("127.0.0.1", 0) do |listener|
        host = "#{tls ? 'localhost' : '127.0.0.1'}:#{listener.local_address.ip_port}"
        endpoint = Async::HTTP::Endpoint.parse("#{tls ? 'wss' : 'ws'}://#{host}/live_fixture")
        listener = OpenSSL::SSL::SSLServer.new(listener, tls_context) if tls
        server = Async::HTTP::Server.for(endpoint) do |request|
          requests << request.path.delete_prefix("/")
          response = script.shift or raise "Unexpected sideband request"
          if tls && (request.method != "GET" || request.path != "/v1/live/sessions/live_fixture/attach")
            next Protocol::HTTP::Response[400, {}, [ "private TLS response body" ]]
          end

          case response
          when Integer
            Protocol::HTTP::Response[response, { "x-fixture" => "private response header" }, [ "private response body" ]]
          when Protocol::HTTP::Response then response
          else
            Async::WebSocket::Adapters::HTTP.open(request) do |socket|
              if response.respond_to?(:call)
                response.call(socket)
              else
                response.each { |event| socket.write(event.to_json) }
                socket.flush
              end
            end
          end
        end
        Async::WebSocket::Client.define_singleton_method(:connect) do |remote, **options, &block|
          local = tls ? Async::HTTP::Endpoint.parse("wss://#{host}#{remote.path}", alpn_protocols: remote.alpn_protocols) : endpoint
          connect.call(local, **options, &block)
        end
        Sync do |task|
          worker = task.async do |acceptor|
            loop do
              peer, address = listener.accept
              acceptor.async { server.accept(peer, address) }
            end
          end
          events = []
          outcome = task.with_timeout(3) { DurableAssistants::Live.attach("synthetic-key", "live_fixture", call_id: 4) { events << it } }
          [ events, requests, outcome ]
        ensure
          worker&.stop
        end
      end
    ensure
      Async::WebSocket::Client.define_singleton_method(:connect, connect)
    end

    def tls_context
      key = OpenSSL::PKey::EC.generate("prime256v1")
      cert = OpenSSL::X509::Certificate.new
      cert.version, cert.serial, cert.public_key = 2, 1, key
      cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=localhost")
      cert.not_before, cert.not_after = 1.minute.ago, 1.minute.from_now
      cert.sign(key, OpenSSL::Digest.new("SHA256"))
      OpenSSL::SSL::SSLContext.new.tap do |context|
        context.cert, context.key = cert, key
        context.alpn_select_cb = ->(protocols) { protocols.include?("h2") ? "h2" : "http/1.1" }
      end
    end
end
