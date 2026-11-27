require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/concourse_test_helper"

class WorkspaceAgentSetupsTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include ConcourseTestHelper

  setup do
    @owner = create_user(name: "Taylor")
    @operator = create_user(name: "Morgan")
    @other = create_user(name: "Reese")
    @team = Workspace.make(name: "Team", owner: @owner)
    @foreign = Workspace.make(name: "Other", owner: @owner)
    [ @team, @foreign ].each do |workspace|
      [ @operator, @other ].each { |user| workspace.memberships.create!(user: user, role: "member") }
    end
    @manager = @owner.start_agent("Lead", workspace: @team)
    @foreign_manager = @owner.start_agent("Lead elsewhere", workspace: @foreign)
    @concourse = stub_fake_concourse
  end

  test "a named operator executes only the exact approved workspace and attributes, once" do
    setup = approve_setup
    sign_in(@operator)
    get workspace_path(@foreign)
    assert_no_difference -> { @team.agents.count + @foreign.agents.count } do
      post workspace_agent_setup_execution_path(@foreign, setup)
      assert_response :not_found
    end
    assert_difference -> { @team.agents.count }, 1 do
      post workspace_agent_setup_execution_path(@team, setup), params: { agent: { instructions: "Not approved", parent_id: @foreign_manager.id } }
      assert_redirected_to workspace_agent_setup_path(@team, setup)
    end
    agent = @team.agents.find_by!(name: "Research desk")
    assert_equal [ @owner, @manager.id, "Summarize evidence.", @team.id ], [ agent.user, agent.parent_id, agent.instructions, agent.workspace_id ]
    assert_no_difference -> { @team.agents.count } do
      post workspace_agent_setup_execution_path(@team, setup)
      assert_redirected_to workspace_agent_setup_path(@team, setup)
    end
    assert_equal agent, setup.reload.agent
    assert_empty agent.concourse_agents
    assert_equal "Lead", @manager.reload.name
  end

  test "members cannot approve and a different, revoked or removed operator cannot execute" do
    setup = approve_setup
    sign_in(@other)
    assert_no_difference -> { @team.agent_setups.count } do
      post workspace_agent_setups_path(@team), params: { agent_setup: approval_fields }
      assert_response :not_found
    end
    assert_no_difference -> { @team.agents.count } do
      post workspace_agent_setup_execution_path(@team, setup)
      assert_response :not_found
      sign_in(@owner)
      post workspace_agent_setup_revocation_path(@team, setup)
      assert_redirected_to workspace_agent_setup_path(@team, setup)
      sign_in(@operator)
      post workspace_agent_setup_execution_path(@team, setup)
      assert_response :not_found
    end
    second = approve_setup
    sign_in(@operator)
    @team.memberships.find_by!(user: @operator).destroy!
    post workspace_agent_setup_execution_path(@team, second)
    assert_response :not_found
  end

  test "a manager must belong to this workspace at approval and execution" do
    sign_in(@owner)
    assert_no_difference -> { @team.agent_setups.count } do
      post workspace_agent_setups_path(@team), params: { agent_setup: approval_fields.merge(manager_id: @foreign_manager.id) }
      assert_response :unprocessable_entity
    end
    setup = approve_setup
    @manager.move_to(@foreign, by: @owner)
    sign_in(@operator)
    assert_no_difference -> { @team.agents.count } do
      post workspace_agent_setup_execution_path(@team, setup)
      assert_response :unprocessable_entity
    end
  end

  test "the owner sees the written approval, operator and manager handoff, and can undo without deleting" do
    setup, agent = execute_setup
    sign_in(@operator)
    post workspace_agent_setup_undo_path(@team, setup)
    assert_response :not_found
    sign_in(@owner)
    get workspace_agent_setup_path(@team, setup)
    assert_select "main", /Taylor.*Morgan.*Research desk.*Lead/m
    assert_select "main", /Approved for this setup only\./
    assert_select "main", /own Concourse identity/i
    assert_select "a[href='#{conversation_path(@manager.conversation)}']", /handoff/
    assert_empty @manager.conversation.messages
    assert_no_difference [ -> { @team.agents.count }, -> { @team.conversations.count }, -> { @team.memberships.count } ] do
      post workspace_agent_setup_undo_path(@team, setup)
      assert_redirected_to workspace_agent_setup_path(@team, setup)
    end
    assert agent.reload.conversation.archived?
    assert_nil agent.parent_id
    assert setup.reload.undone_at
    assert_equal @owner, setup.undone_by
  end

  test "undo never overwrites newer work or touches a moved agent" do
    setup, agent = execute_setup
    sign_in(@owner)
    agent.update!(instructions: "New instructions")
    post workspace_agent_setup_undo_path(@team, setup)
    assert_response :conflict
    assert_equal "New instructions", agent.reload.instructions
    refute agent.conversation.archived?
    agent.move_to(@foreign, by: @owner)
    post workspace_agent_setup_undo_path(@team, setup)
    assert_response :conflict
    assert_equal @foreign, agent.reload.workspace
  end

  test "manager handoff neither opens OAuth nor lends the manager's Concourse permission" do
    _setup, agent = execute_setup
    create_concourse_agent(@manager, status: "admitted")
    assert_includes @manager.tools([]), Tool::ConcourseSend
    get workspace_agent_setup_path(@team, _setup)
    assert_select "a[href='#{new_agent_concourse_join_path(agent)}']", count: 0
    assert_empty agent.concourse_agents
    refute_includes agent.tools([]), Tool::ConcourseSend
    assert_empty @concourse.agents
  end

  test "replaying an authorization form does not give the operator another setup" do
    sign_in(@owner)
    approved = approval_fields
    assert_difference -> { @team.agent_setups.count }, 1 do
      2.times { post workspace_agent_setups_path(@team), params: { agent_setup: approved } }
    end
    setup = @team.agent_setups.sole
    assert_redirected_to workspace_agent_setup_path(@team, setup)
    assert_no_difference -> { @team.agent_setups.count } do
      post workspace_agent_setups_path(@team), params: { agent_setup: approved.merge(instructions: "Different") }
      assert_response :conflict
    end
    assert_equal approved[:instructions], setup.reload.instructions
  end

  private
    def sign_in(user)
      sign_in_via_ajent(subject: user.oidc_sub, email: user.email, name: user.name)
    end

    def approval_fields
      { operator_id: @operator.id, name: "Research desk", instructions: "Summarize evidence.", manager_id: @manager.id,
        authorization: "Approved for this setup only.", request_id: SecureRandom.uuid }
    end

    def approve_setup(**attributes)
      sign_in(@owner)
      post workspace_agent_setups_path(@team), params: { agent_setup: approval_fields.merge(attributes) }
      setup = @team.agent_setups.order(:id).last!
      assert_redirected_to workspace_agent_setup_path(@team, setup)
      setup
    end

    def execute_setup(**attributes)
      setup = approve_setup(**attributes)
      sign_in(@operator)
      post workspace_agent_setup_execution_path(@team, setup)
      assert_redirected_to workspace_agent_setup_path(@team, setup)
      [ setup, setup.reload.agent ]
    end
end
