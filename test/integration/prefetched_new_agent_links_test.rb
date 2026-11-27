require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# Turbo fetches a page ahead of a click (X-Sec-Purpose: prefetch), and that
# never makes its workspace the session's (Authentication#work_in). Opened
# from that prefetch, its New agent links must still name the page's own
# workspace rather than lean on the session's.
class PrefetchedNewAgentLinksTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  setup do
    install_sidecar_settings
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/\d+(\?.*)?\z}).to_return(body: { status: "idle", failure: nil, pendingInputs: [] }.to_json)
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/\d+/entries}).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
    alice = create_user(name: "Alice", email: "member@example.com")
    sign_in_via_ajent
    @bob = User.find_by!(oidc_sub: "42") # tenancy-ok: the test reads the person it signed in
    @bob.start_agent("Bob's own") if @bob.agents.none?
    @household = Workspace.create!(name: "Household")
    @household.memberships.create!(user: alice, role: "owner")
    @household.memberships.create!(user: @bob, role: "member")
    @planner = alice.start_agent("Planner", workspace: @household)
    @planner.conversation.update!(durable_id: "41", request_id: "r-41")
    @card = @planner.conversation.invocations.create!(task_id: "7", call_id: "toolu_q", tool_name: "ask_person",
      arguments: { "question" => "Which evening for dinner?" }, digest: "q", state: "awaiting_person", expires_at: 1.day.from_now)
  end
  teardown { remove_sidecar_settings }

  test "a prefetched card or thread of another workspace names that workspace in its New agent links" do
    get conversations_path
    household = new_agent_path(workspace_id: @household.id)

    get approval_path(@card), headers: { "X-Sec-Purpose" => "prefetch" }
    assert_response :success
    assert_select "body[data-shortcuts-new-agent-value=?]", household

    get conversation_path(@planner.conversation), headers: { "X-Sec-Purpose" => "prefetch" }
    assert_response :success
    assert_select "body[data-shortcuts-new-agent-value=?]", household
    assert_select "form#command_new input[type=hidden][name=workspace_id][value=?]", @household.id.to_s
  end
end
