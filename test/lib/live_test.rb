require "test_helper"

# OpenAI's Live call control: an error names the HTTP status, never the body or the key.
class LiveTest < ActiveSupport::TestCase
  KEY = "sk-fake-#{SecureRandom.hex(8)}".freeze
  URL = "https://api.openai.com/v1/live/sessions/live_fixture/reject".freeze

  test "declines with 603; a refusal is an Error and a server error Unknown, each with the status alone" do
    stub_request(:post, URL).with(body: { status_code: 603 }.to_json).to_return({ status: 401, body: "bad key #{KEY}" }, { status: 502, body: KEY })
    refused = assert_raises(DurableAssistants::Live::Error) { DurableAssistants::Live.reject(KEY, "live_fixture") }
    assert_equal "OpenAI answered HTTP 401 to reject", refused.message
    assert_raises(DurableAssistants::Live::Unknown) { DurableAssistants::Live.reject(KEY, "live_fixture") }
    assert_raises(DurableAssistants::Live::Error) { DurableAssistants::Live.reject(KEY, "../files") }
  end

  test "follows a call on its sideband, with the key in the header, until it closes, skipping what isn't an event" do
    sent = [ "{not JSON", "[1]", { type: "session.input_transcript.delta", delta: "Hi" }.to_json,
      { type: "session.closed", reason: "remote_hangup" }.to_json, { type: "after.close" }.to_json ]
    events = following(sent) { |log| DurableAssistants::Live.attach(KEY, "live_fixture") { log << it } }
    assert_equal [ "wss://api.openai.com/v1/live/sessions/live_fixture/attach", [ [ "authorization", "Bearer #{KEY}" ] ] ], @connected
    assert_equal [ { "type" => "session.input_transcript.delta", "delta" => "Hi" }, { "type" => "session.closed", "reason" => "remote_hangup" } ], events
    assert_raises(DurableAssistants::Live::Error) { DurableAssistants::Live.attach(KEY, "../files") { flunk } }
  end

  test "a sideband that breaks is an Error naming only what broke, never the key or the session" do
    lost = assert_raises(DurableAssistants::Live::Error) do
      following(Protocol::WebSocket::ProtocolError.new("bad frame")) { DurableAssistants::Live.attach(KEY, "live_fixture") { flunk } }
    end
    assert_equal "Lost the call's events (ProtocolError)", lost.message
    reset = assert_raises(DurableAssistants::Live::Error) do
      following(Errno::ECONNRESET.new("#{KEY} live_fixture")) { DurableAssistants::Live.attach(KEY, "live_fixture") { flunk } }
    end
    assert_equal "Lost the call's events (ECONNRESET)", reset.message
  end

  test "answers on the same connection, as JSON, and work beside the events stops when the call does" do
    sent = [ { type: "response.event" }.to_json, { type: "session.input_transcript.delta", delta: "Hi" }.to_json, { type: "session.closed" }.to_json ]
    waited, heard, started = nil, [], Process.clock_gettime(Process::CLOCK_MONOTONIC)
    following(sent) do
      DurableAssistants::Live.attach(KEY, "live_fixture") do |event, sideband|
        heard << event["type"]
        next unless event["type"] == "response.event"
        sideband.write(type: "response.create")
        sideband.async { waited = :waiting; sleep 30; waited = :done }
      end
    end
    assert_equal [ { "type" => "response.create" } ], @written.map { JSON.parse(it.to_str) }
    assert_equal %w[ response.event session.input_transcript.delta session.closed ], heard, "the wait held up no event"
    assert_equal :waiting, waited
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 10
  end

  private
    Connection = Struct.new(:messages, :written) do
      def read
        message = messages.shift
        raise message if message.is_a?(Exception)
        Protocol::WebSocket::TextMessage.new(message) if message
      end

      def write(message) = written << message
      def flush; end
    end

    # The sideband's socket, scripted: the URL and headers it was opened with, and what it sends.
    def following(messages)
      connect, connected, written = Async::WebSocket::Client.method(:connect), (@connected = []), (@written = [])
      Async::WebSocket::Client.define_singleton_method(:connect) do |endpoint, headers:, &block|
        connected.push(endpoint.url.to_s, headers)
        block.call(Connection.new(Array(messages).dup, written))
      end
      [].tap { yield it }
    ensure
      Async::WebSocket::Client.define_singleton_method(:connect, connect)
    end
end
