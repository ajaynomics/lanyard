require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

# #82: an agent's cards reach its people as priority notifications until the
# owner of its workspace lowers them, on its General page, to regular. Another
# member sees how they arrive but cannot change it.
class Agents::PriorityNotificationsControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  setup do
    sign_in_via_ajent
    @owner = User.find_by!(oidc_sub: "42") # tenancy-ok: test reads the person it signed in
    @agent = @owner.agents.sole
  end

  test "the owner lowers the agent's notifications to regular, and raises them again" do
    get agent_path(@agent)
    assert_select "#agent_notifications form[action=?] input[type=checkbox][role=switch][name='agent[priority_notifications]'][checked]",
      agent_priority_notifications_path(@agent)
    assert_select "#agent_notifications input[role=switch][disabled]", count: 0
    assert_select "#agent_notifications", text: /sound/

    patch agent_priority_notifications_path(@agent), params: { agent: { priority_notifications: "0" } }
    assert_response :see_other
    assert_not @agent.reload.priority_notifications?
    get agent_path(@agent)
    assert_select "#agent_notifications input[name='agent[priority_notifications]'][checked]", count: 0
    assert_select "#agent_notifications", text: /quietly/

    patch agent_priority_notifications_path(@agent), params: { agent: { priority_notifications: "1" } }
    assert @agent.reload.priority_notifications?
  end

  test "another member of a shared workspace sees it read-only, and her change is refused" do
    shared = Workspace.create!(name: "Household")
    shared.memberships.create!(user: @owner, role: "owner")
    agent = shared.agents.create!(user: @owner, name: "Shared", instructions: "Help.", model: Agent.models.first)
    shared.memberships.create!(user: create_user(name: "Bob"), role: "member")
    reset!
    sign_in_via_ajent(name: "Bob", subject: "sub-bob", email: "bob@example.com")
    get workspace_path(shared)

    get agent_path(agent)
    assert_response :success
    assert_select "#agent_notifications input[role=switch][name='agent[priority_notifications]'][checked][disabled]"
    assert_select "#agent_notifications", text: /Only Test Operator changes this/

    patch agent_priority_notifications_path(agent), params: { agent: { priority_notifications: "0" } }
    assert_response :not_found
    patch agent_path(agent), params: { agent: { priority_notifications: "0" } }
    assert agent.reload.priority_notifications?
  end
end
