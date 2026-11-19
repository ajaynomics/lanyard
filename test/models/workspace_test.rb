require "test_helper"
require_relative "../test_helpers/agent_test_helper"

class WorkspaceTest < ActiveSupport::TestCase
  include AgentTestHelper

  test "a person's agents are in their personal workspace, which they own and which shows their name" do
    alice = create_user(name: "Alice")
    planner = alice.start_agent("Planner", email_name: "planner")

    workspace = alice.personal_workspace
    assert workspace.personal?
    assert_equal [ workspace ], alice.agents.map(&:workspace).uniq
    assert_equal [ alice ], workspace.members
    assert_equal [ "owner" ], workspace.memberships.map(&:role)
    assert_equal "Alice", workspace.to_s
    assert_not_equal workspace, create_user(name: "Bob").personal_workspace
    assert_equal workspace, planner.reload.workspace
  end

  test "an agent is made in the workspace asked for" do
    alice = create_user(name: "Alice")
    shared = Workspace.create!(name: "Household").tap { it.memberships.create!(user: alice, role: "owner") }

    assert_equal shared, alice.start_agent("Cook", workspace: shared).workspace
    assert_equal "Household", shared.to_s
  end

  test "a name, personal or shared, is at most 100 characters; a personal one may be blank, a shared one may not" do
    alice = create_user(name: "Alice")
    personal = alice.personal_workspace
    shared = Workspace.create!(name: "Household").tap { it.memberships.create!(user: alice, role: "owner") }

    assert personal.update(name: nil)
    assert_not personal.update(name: "a" * 101)
    assert_not shared.update(name: "a" * 101)
    assert_not shared.update(name: nil)
    assert personal.update(name: "a" * 100)
  end

  test "until a rename is saved it goes by its saved name" do
    alice = create_user(name: "Alice")
    shared = Workspace.create!(name: "Household").tap { it.memberships.create!(user: alice, role: "owner") }
    personal = alice.personal_workspace

    assert_not shared.update(name: nil)
    assert_equal "Household", shared.saved_name
    assert_not personal.update(name: "a" * 101)
    assert_equal "Alice", personal.saved_name
  end

  test "a workspace has many members and exactly one owner" do
    alice, bob, sam = create_user(name: "Alice"), create_user(name: "Bob"), create_user(name: "Sam")
    shared = Workspace.create!(name: "Household")
    shared.memberships.create!(user: alice, role: "owner")

    assert shared.memberships.create(user: bob, role: "member").persisted?
    assert shared.memberships.create(user: sam, role: "member").persisted?
    second = shared.memberships.new(user: create_user(name: "Robin"), role: "owner")
    assert_not second.valid?
    assert_includes second.errors[:role], "is taken: a workspace has one owner"
    assert_raises(ArgumentError) { shared.memberships.new(user: bob, role: "viewer") }
    assert_equal alice, shared.owner
  end

  test "the session's workspace stands while the person belongs to it, and their personal one otherwise" do
    alice, bob = create_user(name: "Alice"), create_user(name: "Bob")
    shared = Workspace.create!(name: "Household")
    shared.memberships.create!(user: alice, role: "owner")
    membership = shared.memberships.create!(user: bob, role: "member")

    assert_equal shared, bob.workspace_for(shared.id)
    assert_equal bob.personal_workspace, bob.workspace_for(alice.personal_workspace.id)
    assert_equal bob.personal_workspace, bob.workspace_for(nil)
    membership.destroy!
    assert_equal bob.personal_workspace, bob.workspace_for(shared.id)
  end

  test "a connector records its workspace: a person's their personal one, a conversation's its agent's" do
    alice = create_user(name: "Alice")
    shared = Workspace.create!(name: "Household").tap { it.memberships.create!(user: alice, role: "owner") }
    cook = alice.start_agent("Cook", workspace: shared)

    assert_equal alice.personal_workspace, alice.mcp_servers.create!(name: "mine", url: "https://example.com/mcp").workspace
    assert_equal shared, alice.mcp_servers.create!(name: "cooking", url: "https://example.com/mcp", conversation: cook.conversation).workspace
  end

  # docs/design/workspaces.md, 2.3 and 3: naming the home network never stops
  # an identity that spoke. Each one left outside it is a bridge, approved by
  # whoever named the home; one waiting for approval waits on, unless it is
  # in the new home.
  test "naming a home network keeps every identity speaking, those outside it bridges its namer approved" do
    carol, dave = create_user(name: "Carol"), create_user(name: "Dave")
    team = Workspace.create!(name: "Team").tap do
      it.memberships.create!(user: carol, role: "owner")
      it.memberships.create!(user: dave, role: "member")
    end
    agent = team.agents.create!(user: carol, name: "Ada", instructions: "Help.", model: Agent.models.first)
    acme, example = %w[ acme example ].map { agent.concourse_agents.create!(organization: it, handle: "#{it}/ada", client_id: "c-#{it}", client_secret: "s-#{it}") }
    assert_equal [ acme, example ], agent.concourse_networks, "with no home network, as today"

    assert team.name_concourse_home("acme", by: carol)
    assert_not acme.reload.bridge?
    assert example.reload.bridge?
    assert_equal carol, example.bridge_approved_by
    assert_equal [ acme, example ], agent.reload.concourse_networks

    waiting = agent.concourse_agents.create!(organization: "pilot", handle: "pilot/ada", client_id: "c-p", client_secret: "s-p")
    assert waiting.waiting_for_owner?
    assert_not team.name_concourse_home("no such network!", by: carol)
    assert_equal "acme", team.reload.concourse_home

    team.name_concourse_home("pilot", by: carol)
    assert_not waiting.reload.bridge?, "the new home's identity is an ordinary join"
    assert_equal carol, acme.reload.bridge_approved_by, "the old home's speaks on, a bridge now"
    assert_equal [ acme, example, waiting ], agent.reload.concourse_networks

    team.name_concourse_home("", by: carol)
    assert_nil team.reload.concourse_home
    assert agent.reload.concourse_agents.none?(&:bridge?)
  end
end
