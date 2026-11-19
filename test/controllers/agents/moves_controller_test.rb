require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

# Move, on an agent's settings: its workspace's owner alone, to one of her
# other workspaces, and she then works there.
class Agents::MovesControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    @person = User.find_by!(oidc_sub: "42") # tenancy-ok: test reads the person it signed in
    @agent = @person.agents.sole
    @alice = create_user(name: "Alice")
    @team = Workspace.create!(name: "Team")
    @team.memberships.create!(user: @alice, role: "owner")
    @team.memberships.create!(user: @person, role: "member")
  end
  teardown { remove_sidecar_settings }

  test "her own workspace's agent shows its workspace and moves to one she is in, which she then works in" do
    get agent_path(@agent)
    assert_select "#agent_workspace .ui-row__value", text: /Test Operator/
    assert_select "#agent_workspace a[href=?]", new_agent_move_path(@agent), text: "Move"

    get new_agent_move_path(@agent)
    assert_select "input[type=radio][name='move[workspace_id]'][value=?]", @team.id.to_s
    assert_select "input[type=radio][value=?]", @person.personal_workspace.id.to_s, count: 0

    post agent_move_path(@agent), params: { move: { workspace_id: @team.id } }
    assert_redirected_to agent_path(@agent)
    assert_equal @team, @agent.reload.workspace
    assert_equal @team.id, session[:workspace_id]
  end

  # #227: a number is on one voip.ms account, and a move doesn't take it to another.
  test "moving to a workspace whose voip.ms account differs warns in one line that the number stays, and the move still goes ahead" do
    @team.update!(voipms_vault_entry: "Team voip.ms")
    plain = Workspace.make(name: "Plain", owner: @person)
    get new_agent_move_path(@agent)
    assert_select ".choice__warning", count: 0, message: "without a number, nothing to warn of"

    @agent.update!(phone_number: "4165550100")

    get new_agent_move_path(@agent)
    assert_select "#move_to_workspace_#{@team.id} .choice__warning", count: 1, text: /number stays on its current voip\.ms account/
    assert_select "#move_to_workspace_#{plain.id} .choice__warning", count: 0
    assert_not_includes response.body, "Team voip.ms", "the entry's name is the workspace owner's"

    ours = Workspace.make(name: "Ours", owner: @person)
    ours.update!(voipms_vault_entry: "Ours voip.ms")
    plain.update!(voipms_vault_entry: "ours VOIP.ms")
    @agent.update!(workspace: ours)
    get workspace_path(ours)
    get new_agent_move_path(@agent)
    assert_select "#move_to_workspace_#{@team.id} .choice__warning", count: 1, text: /number stays on its current voip\.ms account/
    assert_select "#move_to_workspace_#{plain.id} .choice__warning", count: 0
    assert_select "#move_to_workspace_#{@person.personal_workspace.id} .choice__warning", count: 1

    post agent_move_path(@agent), params: { move: { workspace_id: @team.id } }
    assert_redirected_to agent_path(@agent)
    assert_equal [ @team, "4165550100" ], [ @agent.reload.workspace, @agent.phone_number ]
  end

  test "a member who doesn't own its workspace finds no Move, and a workspace she isn't in is not found" do
    shared = @alice.start_agent("Tess", workspace: @team)
    get workspace_path(@team)
    get agent_path(shared)
    assert_select "#agent_workspace a", text: "Move", count: 0
    get new_agent_move_path(shared)
    assert_response :not_found
    post agent_move_path(shared), params: { move: { workspace_id: @person.personal_workspace.id } }
    assert_response :not_found
    assert_equal @team, shared.reload.workspace

    get workspace_path(@person.personal_workspace)
    post agent_move_path(@agent), params: { move: { workspace_id: @alice.personal_workspace.id } }
    assert_response :not_found
    assert_equal @person.personal_workspace, @agent.reload.workspace
  end

  test "someone in only their own workspace sees nothing of workspaces on the agent's page" do
    @team.memberships.find_by!(user: @person).destroy!
    get agent_path(@agent)
    assert_select "#agent_workspace", count: 0
  end
end
