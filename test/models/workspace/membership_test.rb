require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

# What leaving a shared workspace takes with it, and how its one owner hands
# it on. Alice owns the shared workspace; Bob is a member.
class Workspace::MembershipTest < ActiveSupport::TestCase
  include AgentTestHelper

  setup do
    @alice, @bob = %w[ Alice Bob ].map { create_user(name: it) }
    @shared = Workspace.create!(name: "Household")
    @alices_membership = @shared.memberships.create!(user: @alice, role: "owner")
    @bobs_membership = @shared.memberships.create!(user: @bob, role: "member")
    @agent = @shared.agents.create!(user: @alice, name: "Iris", instructions: "Help.", model: Agent.models.first)
  end

  # An "Always" lets the agent act unasked on the word of the person who gave
  # it; once they are out, their word no longer stands for anyone there.
  test "removed, a member's Always for the workspace's agents is gone; others' and their own elsewhere stay" do
    @agent.permissions.create!(tool_name: "send_email", recipient: "", granted_by: @bob)
    @agent.permissions.create!(tool_name: "send_email", recipient: "friend@example.com", granted_by: @alice)
    own = @bob.personal_workspace.agents.first.permissions.create!(tool_name: "send_email", recipient: "", granted_by: @bob)

    @bobs_membership.destroy!

    assert_equal [ @alice ], @agent.permissions.reload.map(&:granted_by)
    assert Permission.exists?(own.id), "his own agent keeps his Always"
  end
end
