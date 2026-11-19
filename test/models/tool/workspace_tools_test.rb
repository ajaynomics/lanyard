require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

# An agent doing what the workspace pages do, through the same model methods,
# each change on a card only the workspace's owner answers.
class Tool::WorkspaceToolsTest < ActiveSupport::TestCase
  include AgentTestHelper
  include ActiveJob::TestHelper

  TOOLS = %w[ list_workspaces make_workspace rename_workspace invite_to_workspace change_workspace_member move_agent ].freeze

  setup do
    @alice = create_user(name: "Alice")
    @bob = create_user(name: "Bob")
    @team = Workspace.create!(name: "Team")
    @team.memberships.create!(user: @alice, role: "owner")
    @team.memberships.create!(user: @bob, role: "member")
    @tess = @bob.start_agent("Tess", workspace: @team)
    @agent = @alice.personal_workspace.agents.sole
    @agent.update!(tool_names: @agent.tool_names | TOOLS)
    @conversation = create_conversation(@agent)
  end

  test "they are picked one by one: no starter has them, so no agent's tool count rises unasked" do
    TOOLS.each { assert Tool::Catalog.find(it), it }
    starters = Dir[Rails.root.join("config/agents/*/agent.yml")].flat_map { YAML.safe_load_file(it).fetch("tools") }
    assert_empty starters & TOOLS
    assert_empty @alice.start_agent("Fresh").tool_names & TOOLS
    assert_operator @agent.tool_count, :<=, Agent::TOOL_LIMIT
  end

  test "list_workspaces names every workspace of its person's, from her own, with no card" do
    @team.invitations.create!(email: "carol@example.com", inviter: @alice)

    result = call("list_workspaces", {})[:result]
    assert_equal [ "Alice", "Team" ], result[:workspaces].pluck(:name)
    own, team = result[:workspaces]
    assert own[:yours]
    assert own[:here]
    assert_equal [ @agent.name ], own[:agents]
    assert_equal [ { name: "Alice", email: "alice@example.com", role: "owner" }, { name: "Bob", email: "bob@example.com", role: "member" } ], team[:members]
    assert_equal [ "carol@example.com" ], team[:invited]
    assert_equal [ "Tess" ], team[:agents]
  end

  test "in a shared workspace it names that one alone, which everyone there may know" do
    @tess.update!(tool_names: @tess.tool_names | TOOLS)
    @conversation = create_conversation(@tess, durable_id: "13")

    result = call("list_workspaces", {})[:result]
    assert_equal [ "Team" ], result[:workspaces].pluck(:name)
    assert_not result[:workspaces].sole.key?(:invited), "invitations are its owner's to see"

    refused = call("rename_workspace", { "workspace" => "Alice", "name" => "Mine" }, call_id: "rename")
    assert refused[:isError]
    assert_match(/no workspace you can name is called Alice/i, refused.dig(:result, :error))
    assert_empty @conversation.invocations.awaiting_person, "refused before anyone is asked"
  end

  test "make_workspace makes a shared workspace its person owns, once she allows it" do
    assert_equal "waiting", call("make_workspace", { "name" => "Studio" }, call_id: "make")[:status]
    assert_not Workspace.exists?(name: "Studio")

    result = approve("make", "make_workspace", { "name" => "Studio" })[:result]
    assert_equal({ made: "Studio", owner: "Alice" }, result)
    assert_equal @alice, Workspace.find_by!(name: "Studio").owner
  end

  test "rename_workspace renames one of hers by name" do
    approve("rename", "rename_workspace", { "workspace" => "Team", "name" => "Crew" })
    assert_equal "Crew", @team.reload.name
  end

  test "invite_to_workspace invites as the Invite button does, asking even where the install approves everything" do
    with_setting(:app, :approve_everything, true) do
      assert_equal "waiting", call("invite_to_workspace", { "workspace" => "Team", "email" => "carol@example.com" }, call_id: "inv")[:status]
    end
    assert_not @team.invitations.exists?

    result = approve("inv", "invite_to_workspace", { "workspace" => "Team", "email" => "carol@example.com" })[:result]
    assert_equal({ invited: "carol@example.com", waits_for_an_admin: true }, result)
    assert @team.invitations.find_by!(email: "carol@example.com").awaiting_approval?

    studio = Workspace.create!(name: "Studio").tap { it.memberships.create!(user: @alice, role: "owner") }
    result = approve("inv-bob", "invite_to_workspace", { "workspace" => "Studio", "email" => "bob@example.com" })[:result]
    assert_equal({ added: "Bob" }, result, "someone the install already lets in joins at once")
    assert studio.member?(@bob)
  end

  test "invite_to_workspace invites nobody where the install serves one person, as the Invite button doesn't" do
    with_setting(:access, :owner, "operator@example.com") do
      call("invite_to_workspace", { "workspace" => "Team", "email" => "carol@example.com" }, call_id: "inv")
      @conversation.invocations.find_by!(call_id: "inv").approve!(by: @alice)
      refused = call("invite_to_workspace", { "workspace" => "Team", "email" => "carol@example.com" }, call_id: "inv")

      assert_equal Workspace::Invitation::REFUSED_FOR_ONE_OWNER, refused.dig(:result, :error)
      assert_not @team.invitations.exists?
    end
  end

  test "change_workspace_member hands the workspace over, removes a member and cancels an invitation" do
    @team.invitations.create!(email: "carol@example.com", inviter: @alice)

    approve("own", "change_workspace_member", { "workspace" => "Team", "email" => "bob@example.com", "change" => "make_owner" })
    assert_equal @bob, @team.reload.owner

    @team.memberships.find_by!(user: @alice).take_ownership
    approve("rm", "change_workspace_member", { "workspace" => "Team", "email" => "bob@example.com", "change" => "remove" })
    assert_not @team.reload.member?(@bob)

    approve("cancel", "change_workspace_member", { "workspace" => "Team", "email" => "carol@example.com", "change" => "remove" })
    assert_empty @team.invitations
  end

  test "move_agent moves an agent of hers to another of her workspaces, as its Move page does" do
    approve("move", "move_agent", { "agent" => "Tess", "to" => "Alice" })
    assert_equal @alice.personal_workspace, @tess.reload.workspace
  end

  test "only the workspace's owner answers the card; a denied card changes nothing" do
    calls = {
      "make" => [ "make_workspace", { "name" => "Studio" } ],
      "rename" => [ "rename_workspace", { "workspace" => "Team", "name" => "Crew" } ],
      "inv" => [ "invite_to_workspace", { "workspace" => "Team", "email" => "carol@example.com" } ],
      "rm" => [ "change_workspace_member", { "workspace" => "Team", "email" => "bob@example.com", "change" => "remove" } ],
      "move" => [ "move_agent", { "agent" => "Tess", "to" => "Alice" } ]
    }
    before = [ Workspace.count, @team.reload.attributes, @team.memberships.pluck(:user_id, :role), @team.invitations.count, @tess.reload.workspace_id ]

    calls.each do |call_id, (tool, arguments)|
      assert_equal "waiting", call(tool, arguments, call_id: call_id)[:status], tool
      card = @conversation.invocations.find_by!(call_id: call_id)
      assert_equal @alice, card.approver
      assert_raises(Invocation::NotTheApprover) { card.approve!(by: @bob) }
      card.deny!(by: @alice)
      outcome = call(tool, arguments, call_id: call_id)
      assert outcome[:isError], tool
      assert_match(/Alice declined #{tool}/, outcome.dig(:result, :error))
    end

    assert_equal before, [ Workspace.count, @team.reload.attributes, @team.memberships.pluck(:user_id, :role), @team.invitations.count, @tess.reload.workspace_id ]
  end

  test "what she may not do on the pages, she may not do through an agent" do
    studio = Workspace.create!(name: "Studio").tap { it.memberships.create!(user: @bob, role: "owner") }
    studio.memberships.create!(user: @alice, role: "member")

    refused = call("invite_to_workspace", { "workspace" => "Studio", "email" => "carol@example.com" }, call_id: "inv")
    assert_match(/Only Bob, who owns Studio, can invite/, refused.dig(:result, :error))
    refused = call("rename_workspace", { "workspace" => "Alice", "name" => "Mine" }, call_id: "rename")
    assert_match(/goes by its person's name/, refused.dig(:result, :error))
    refused = call("move_agent", { "agent" => "Nobody", "to" => "Team" }, call_id: "move")
    assert_match(/no agent you can name is called Nobody/i, refused.dig(:result, :error))
    assert_empty @conversation.invocations.awaiting_person
  end

  private
    def call(tool, arguments, call_id: "toolu_1")
      payload = invocation_payload(@conversation, tool: tool, arguments: arguments, call_id: call_id)
      Invocation.receive(@conversation, task_id: payload[:taskId], call_id: call_id, tool: tool,
        arguments: arguments, digest: payload[:digest]).deep_symbolize_keys
    end

    # The call as the sidecar replays it after Alice allows it.
    def approve(call_id, tool, arguments)
      call(tool, arguments, call_id: call_id)
      @conversation.invocations.find_by!(call_id: call_id).approve!(by: @alice)
      call(tool, arguments, call_id: call_id).tap { assert_not it[:isError], it.to_json }
    end
end
