require "test_helper"
require_relative "../test_helpers/agent_test_helper"

class AgentTemplatesTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  test "a workspace member picks a preset on the normal form and its purpose comes before theirs" do
    owner = create_user(name: "Owner", email: "owner@example.com")
    member = create_user(name: "Member", email: "member@example.com")
    workspace = Workspace.make(name: "Studio", owner: owner)
    workspace.memberships.create!(user: member, role: "member")
    sign_in_via_ajent(subject: member.oidc_sub, email: member.email)

    get new_agent_path(workspace_id: workspace.id)
    assert_response :ok
    assert_select "select[name='agent[template]'] option[value=research]", "Research"

    assert_difference -> { workspace.agents.count }, 1 do
      post agents_path, params: { agent: { name: "Research desk", workspace_id: workspace.id, template: "research", purpose: "Help our studio." } }
    end
    agent = workspace.agents.sole
    assert_redirected_to conversation_path(agent.conversation)
    assert_equal member, agent.user
    assert agent.instructions.end_with?("#{Agent::Template.all.find { it.key == 'research' }.purpose}\n\nHelp our studio.")
  end
end
