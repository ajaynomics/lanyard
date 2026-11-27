require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# The screen is a websocket to the sidecar (PiDurable::Client#screen). WebMock
# swaps Async::HTTP::Client for a stand-in with no connection pool, which a
# websocket needs; under it the screen died in the request's fiber with a
# NoMethodError rather than failing as an unreachable sidecar does.
class PiDurableScreenTest < ActiveSupport::TestCase
  include AgentTestHelper

  Access = Struct.new(:actor_id, :workspace_id)

  setup { install_sidecar_settings }
  teardown { remove_sidecar_settings }

  test "a screen whose sidecar can't be reached fails as the client's own error, which the relay closes the browser on" do
    assert_raises(DurableAssistants::PiDurable::Client::Error) do
      DurableAssistants::PiDurable::Client.new.screen(Access.new("1", "1"), "12", computer: "c") { flunk "no screen opened" }
    end
  end

  test "a test's websocket never leaves this machine" do
    error = assert_raises(WebMock::NetConnectNotAllowedError) do
      Async::WebSocket::Client.connect(Async::HTTP::Endpoint.parse("http://example.com/screen")) { flunk "connected" }
    end
    assert_match "example.com", error.message
  end
end
