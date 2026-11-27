require "test_helper"

# McpServer::HttpTransport replaces the refresh the `mcp` gem tries after a
# 401 by overriding a private method, as the gem offers no public hook for
# it. The Gemfile pins the gem; this says by name what broke if an upgrade
# moves the method, before a rotating refresh token is sent twice.
class McpServer::HttpTransportTest < ActiveSupport::TestCase
  test "the gem still refreshes after a 401 through attempt_refresh(flow:, resource_metadata_url:)" do
    assert MCP::Client::HTTP.private_method_defined?(:attempt_refresh, false),
      "MCP::Client::HTTP#attempt_refresh is gone in mcp #{MCP::VERSION}: McpServer::HttpTransport no longer replaces the refresh after a 401"
    assert_equal [ [ :keyreq, :flow ], [ :keyreq, :resource_metadata_url ] ], MCP::Client::HTTP.instance_method(:attempt_refresh).parameters,
      "MCP::Client::HTTP#attempt_refresh changed its arguments in mcp #{MCP::VERSION}: McpServer::HttpTransport overrides it"
    assert_equal MCP::Client::HTTP.instance_method(:attempt_refresh).parameters, McpServer::HttpTransport.instance_method(:attempt_refresh).parameters
    assert_includes File.read(MCP::Client::HTTP.instance_method(:run_oauth_flow!).source_location.first), "return if attempt_refresh(flow: flow,",
      "MCP::Client::HTTP#run_oauth_flow! no longer calls attempt_refresh in mcp #{MCP::VERSION}"
  end
end
