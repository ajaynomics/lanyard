require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/fake_oauth_mcp"

# A connector whose gallery entry does not say rotating_refresh (GitHub,
# Google, any added by address) renews as the `mcp` gem does: before a call
# when its token is about to expire, and by the gem's own refresh after a
# 401. No refresh token is claimed: no statement names the claim columns.
# Written to pass unchanged on the code from before McpServer::Renewal.
class McpServer::OrdinaryRenewalTest < ActiveSupport::TestCase
  include AgentTestHelper

  URL = "https://ordinary.example.test/mcp".freeze

  setup do
    @fake = FakeOauthMcp.new
    stub_request(:any, %r{\Ahttps://ordinary\.example\.test/}).to_rack(@fake)
    @connector = create_user.mcp_servers.create!(name: "ordinary", url: URL)
    @connector.finish_sign_in(Rack::Utils.parse_query(URI(Rack::MockRequest.new(@fake).get(@connector.sign_in_url).location).query))
    @fake.token_requests.clear
  end

  test "a token about to expire is renewed before the call, and no claim is made" do
    @connector.update!(oauth_tokens: @connector.oauth_tokens.merge("expires_at" => 1.minute.ago.to_i))
    expired = @connector.oauth_tokens["access_token"]

    statements, refreshers = watching { assert_equal "echo: hi", call_tool }

    assert_equal 1, refreshes
    assert_not_equal expired, @connector.reload.oauth_tokens["access_token"]
    assert_empty refreshers, "no 401, so the gem's refresh after one never ran"
    assert_empty statements.grep(/refresh_claim/), "no claim column is read or written"
  end

  test "a token the server turns away is refreshed by the gem's own refresh, and the call goes through" do
    @fake.expire!

    statements, refreshers = watching { assert_equal "echo: hi", call_tool }

    assert_equal 1, refreshes
    assert_equal [ MCP::Client::HTTP ], refreshers, "the gem's attempt_refresh, not McpServer::HttpTransport's"
    assert_empty statements.grep(/refresh_claim/), "no claim column is read or written"
    assert_equal [ nil, nil ], @connector.reload.attributes.values_at("refresh_claim", "refresh_claimed_at")
  end

  test "a refresh token the server refuses after a 401 asks for a new sign-in, as before" do
    @connector.update!(oauth_tokens: @connector.oauth_tokens.merge("refresh_token" => "revoked"))
    @fake.expire!

    assert_raises(McpServer::SignInNeeded) { call_tool }
    assert_not @connector.reload.signed_in?
    assert_equal [ "revoked" ], @fake.token_requests.filter_map { it["refresh_token"] }, "sent once, by the gem"
  end

  private
    def call_tool = McpServer.find(@connector.id).call_tool("echo", { text: "hi" }).dig("content", 0, "text") # tenancy-ok: the test's own connector, read afresh as a request would

    def refreshes = @fake.token_requests.count { it["grant_type"] == "refresh_token" }

    # Every SQL statement run, and the class whose attempt_refresh (the
    # gem's refresh after a 401) ran, while the block does.
    def watching
      statements, refreshers = [], []
      trace = TracePoint.new(:call) { refreshers << it.defined_class if it.method_id == :attempt_refresh }
      subscription = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql] }
      trace.enable { yield }
      [ statements, refreshers ]
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
    end
end
