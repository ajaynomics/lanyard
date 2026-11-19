require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

# Moving an agent to another workspace (Agent::Movable): what goes with it,
# what stays behind, and who may move it where.
class Agent::MoveTest < ActiveSupport::TestCase
  include AgentTestHelper
  include ActiveJob::TestHelper

  setup do
    @alice = create_user(name: "Alice")
    @bob = create_user(name: "Bob")
    @home = @alice.personal_workspace
    @team = Workspace.create!(name: "Team")
    @team.memberships.create!(user: @alice, role: "owner")
    @bobs_membership = @team.memberships.create!(user: @bob, role: "member", phone_number: "4165550142")
    # Bob made it, in the team Alice owns.
    @agent = @bob.start_agent("Tess", workspace: @team)
  end

  test "its owner moves it to her own workspace: its thread, notes and own connectors go with it; the team's connectors, routes and Bob's word stay" do
    conversation = create_conversation(@agent)
    note = @agent.notes.create!(key: "trip", body: "Lisbon")
    teams = @team.mcp_servers.create!(user: @alice, name: "teamwiki", url: "https://wiki.example.com/mcp")
    @agent.core_connectors.create!(mcp_server: teams)
    @agent.connector_moves.create!(mcp_server: teams, connector_name: "teamwiki", reason: "too many")
    own = @team.mcp_servers.create!(user: @bob, conversation: conversation, name: "threadtool", url: "https://thread.example.com/mcp")
    alices = @agent.permissions.create!(tool_name: "send_email", granted_by: @alice)
    @agent.permissions.create!(tool_name: "forget_note", granted_by: @bob)
    @team.contact_routes.create!(contact: "client@example.com", agent: @agent)
    @bobs_membership.update!(sole_contact: @agent)

    assert @agent.move_to(@home, by: @alice), @agent.errors.full_messages.to_sentence

    @agent.reload
    assert_equal @home, @agent.workspace
    assert_equal conversation, @agent.conversation
    assert_equal [ note ], @agent.notes.to_a
    assert_equal @home, own.reload.workspace, "a thread's own connector goes with its thread"
    assert_empty @agent.core_connectors, "the team's connector stays the team's"
    assert_empty @agent.connector_moves
    assert_equal [ alices ], @agent.permissions.to_a, "Bob is not in Alice's own workspace: his Always goes"
    assert_empty @team.contact_routes.reload, "the team's mail from its client no longer reaches an agent outside it"
    assert_nil @bobs_membership.reload.sole_contact
    assert_not_includes @team.agents, @agent
    assert_includes @home.agents, @agent
    assert_equal @bob, @agent.user, "who made it is kept"
    assert_equal @agent, Agent::Access.resolve(@bob.id.to_s, @agent.id.to_s).agent, "its sidecar's actor, its maker, still reaches it"
  end

  test "only its workspace's owner moves it, only to a workspace she is in, and not where it is" do
    assert_not @agent.move_to(@bob.personal_workspace, by: @bob)
    assert_equal [ "Only Alice, who owns Team, can move Tess." ], @agent.errors.full_messages

    assert_not @agent.move_to(@bob.personal_workspace, by: @alice)
    assert_equal [ "Alice isn't in Bob's workspace, so Tess can't go there." ], @agent.errors.full_messages

    assert_not @agent.move_to(@team, by: @alice)
    assert_equal [ "Tess is in Team already." ], @agent.errors.full_messages
    assert_equal @team, @agent.reload.workspace
  end

  test "an agent that passes its mail to another, or takes another's, stays until that ends" do
    other = @bob.start_agent("Old Tess", workspace: @team)
    other.update!(mail_to_agent: @agent)

    assert_not @agent.move_to(@home, by: @alice)
    assert_equal [ "Old Tess passes its mail to Tess. Stop that first, then move it." ], @agent.errors.full_messages
    assert_equal @team, @agent.reload.workspace
  end

  test "mail goes on only to an agent of the same workspace" do
    elsewhere = @alice.start_agent("Home helper", workspace: @home)
    other = @alice.start_agent("Team helper", workspace: @team)
    other.mail_to_agent = elsewhere
    assert_not other.valid?
    assert_includes other.errors[:mail_to_agent], "must be another agent of the same workspace"
  end

  test "its Campfire bot stays on a shared Campfire, forgetting the team's rooms; to another Campfire it is made anew there" do
    bot = @agent.create_campfire_bot!(bot_key: "4-abc123", rooms: { "3" => "Trips" })
    assert @agent.move_to(@home, by: @alice)
    assert_equal({}, bot.reload.rooms)

    @team.update!(campfire_url: "https://chat.example.com")
    assert @agent.reload.move_to(@team, by: @alice)
    assert_nil @agent.reload.campfire_bot, "its bot on the install's Campfire is gone; the team's Campfire makes its own"
  end

  test "a Concourse identity outside its new home network waits for that workspace's owner" do
    @team.update!(concourse_home: "team")
    identity = @agent.concourse_agents.create!(organization: "team", handle: "team/tess", client_id: "c", client_secret: "s")
    assert identity.speaks?
    studio = Workspace.create!(name: "Studio", concourse_home: "studio")
    studio.memberships.create!(user: @bob, role: "owner")
    studio.memberships.create!(user: @alice, role: "member")

    assert @agent.move_to(studio, by: @alice)
    assert identity.reload.waiting_for_owner?, "Bob owns Studio, so the bridge waits for him"
    assert_not identity.speaks?
  end

  test "agents.workspace_id is required and a foreign key to workspaces" do
    column = Agent.columns_hash["workspace_id"]
    assert_not column.null
    assert ActiveRecord::Base.connection.foreign_keys(:agents).any? { it.to_table == "workspaces" && it.column == "workspace_id" }
  end
end
