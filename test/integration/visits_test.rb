require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/mcp_test_helper"

# Ahoy keeps the app's own record of visits and of the four things worth
# counting. An event carries ids and choices, never what anyone wrote.
class VisitsTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include McpTestHelper
  include ActiveJob::TestHelper

  setup do
    # Ahoy counts a request without a browser's user agent as a bot, which
    # every integration test's is.
    @track_bots, Ahoy.track_bots = Ahoy.track_bots, true
    install_sidecar_settings
    sign_in_via_ajent
    @user = User.find_by!(oidc_sub: "42") # tenancy-ok: test reads the person it signed in
    @agent = @user.agents.sole
  end
  teardown do
    remove_sidecar_settings
    Ahoy.track_bots = @track_bots
  end

  test "signing in opens one visit that is the person's, with the address masked" do
    visit = Ahoy::Visit.sole # tenancy-ok: the test owns the only visit
    assert_equal @user, visit.user
    assert_equal "127.0.0.0", visit.ip

    get agents_path
    assert_equal 1, Ahoy::Visit.count, "one visit, not one per page" # tenancy-ok: counts every visit
  end

  test "creating an agent, sending a message, answering an approval and adding a connector are events, without their words" do
    post agents_path, params: { agent: { name: "Garden planner" } }
    agent = @user.agents.order(:id).last
    conversation = agent.conversation
    conversation.update!(durable_id: "12")

    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").to_return(status: 202, body: { id: 1 }.to_json)
    post conversation_submissions_path(conversation), params: { content: "Plant the tomatoes in May", request_id: "m-1" }

    agent.notes.remember("old", "x")
    payload = invocation_payload(conversation, tool: "forget_note", arguments: { "key" => "old" }, call_id: "c1")
    Invocation.receive(conversation, task_id: payload[:taskId], call_id: "c1", tool: "forget_note", arguments: { "key" => "old" }, digest: payload[:digest])
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/wakes").to_return(body: { rung: true }.to_json)
    post conversation_invocation_approval_path(conversation, conversation.invocations.sole), params: { decision: "approve", always: "agent" }

    post connectors_path, params: { connector: { name: "wiki", url: MCP_URL, token: "secret-token-1", conversation_id: conversation.id } }

    events = @user.ahoy_events.order(:id)
    assert_equal [ "Agent created", "Message sent", "Approval answered", "Connector added" ], events.map(&:name)
    assert events.all? { it.visit == @user.ahoy_visits.sole }
    assert_equal({ "agent_id" => agent.id, "pictures" => 0, "when_busy" => "followUp" }, events.second.properties)
    assert_equal({ "agent_id" => agent.id, "tool" => "forget_note", "decision" => "approve", "always" => "agent" }, events.third.properties)
    assert_equal({ "connector_id" => @user.mcp_servers.sole.id, "agent_id" => agent.id }, events.fourth.properties)
    assert_no_match(/tomatoes|Garden|secret-token|wiki/, events.map { it.properties.to_json }.join)
  end

  test "Ahoy's cookies are not for the page's scripts" do
    open_session do |stranger|
      stranger.get sign_in_path
      cookies = Array(stranger.response.headers["Set-Cookie"]).flat_map(&:lines)
      assert_match(/httponly/i, cookies.grep(/\Aahoy_visit=/).sole)
      assert_match(/httponly/i, cookies.grep(/\Aahoy_visitor=/).sole)
    end
  end

  test "the sidecar's callbacks are not visits" do
    assert_no_difference -> { Ahoy::Visit.count } do # tenancy-ok: counts every visit
      post "/agent/accesses", params: { actorId: @user.id.to_s, workspaceId: @agent.id.to_s }, headers: rails_bearer, as: :json
    end
  end
end
