require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

class Agents::ReportingControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    @owner = User.find_by!(oidc_sub: "42")
    @member = create_user(name: "Bob")
    @team = Workspace.make(name: "Juniper", owner: @owner)
    @team.memberships.create!(user: @member, role: "member")
    @top, @middle, @leaf, @other, @archived = %w[ Aster Rill Pip Sable Cove ].map { @owner.start_agent(it, workspace: @team) }
    @foreign = @member.personal_workspace.agents.sole
  end
  teardown { remove_sidecar_settings }

  test "the owner sees eligible choices and Rails rechecks stale choices on save" do
    @middle.update!(parent_id: @top.id)
    @leaf.update!(parent_id: @middle.id)
    @archived.conversation.archive

    get edit_agent_reporting_path(@middle)
    assert_response :success
    assert_equal [ "", @top.id.to_s, @other.id.to_s ], css_select("input[type=radio]").map { it["value"] }
    assert_select "label", text: /No manager/

    @other.update!(parent_id: @top.id)
    move(@middle, to: @other)
    assert_response :unprocessable_entity
    assert_select "[role=alert]", text: /three levels/
    assert_equal @top, @middle.reload.manager

    move(@middle, to: nil)
    assert_response :see_other
    assert_nil @middle.reload.parent_id
    assert_equal @middle, @leaf.reload.manager
  end

  test "a member cannot open or submit the picker and a foreign manager is rejected" do
    move(@middle, to: @foreign)
    assert_response :unprocessable_entity
    assert_select "input[value=?]", @foreign.id.to_s, count: 0
    assert_nil @middle.reload.parent_id

    sign_in_via_ajent(subject: "sub-bob", email: @member.email, name: "Bob")
    get root_path
    assert_select "#group_workspace_#{@team.id} a", text: "Move in reporting tree…", count: 0
    get edit_agent_reporting_path(@middle)
    assert_response :not_found
    move(@middle, to: @other)
    assert_response :not_found
    assert_nil @middle.reload.parent_id
  end

  test "delete and workspace move confirmations name the promotion destination" do
    @middle.update!(parent_id: @top.id)
    @leaf.update!(parent_id: @middle.id)
    get agent_path(@middle)
    assert_select "#delete_agent", text: /report.*move up to Aster/i
    get new_agent_move_path(@middle)
    assert_select "#agent_move", text: /report.*move up to Aster/i

    @middle.update!(parent_id: nil)
    get agent_path(@middle)
    assert_select "#delete_agent", text: /report.*move up to the top level/i
  end

  test "narrow lists show flat matches with their actual manager and archived ancestors remain in the active tree" do
    @middle.update!(parent_id: @top.id)
    @leaf.update!(parent_id: @middle.id)
    @middle.conversation.archive

    get root_path
    assert_select ".tree-children .conversation-row__badge", text: "Archived"
    assert_select ".tree-children .tree-children .conversation-row__name", text: "Pip"
    get conversations_path(q: "Pip")
    assert_select ".conversation-row", count: 1
    assert_select ".tree-children", count: 0
    assert_select ".tree-row", text: /Reports to Rill/
  end

  test "initial HTML renders authorized reporting groups from a bounded cookie" do
    @middle.update!(parent_id: @top.id)
    @leaf.update!(parent_id: @middle.id)
    get root_path
    assert_select "details[data-group=?][open]", @top.id.to_s
    assert_select "details[data-group=?][open]", @middle.id.to_s

    cookies[:collapsed_agents] = [ @top.id, @leaf.id, @foreign.id, "9" * 19, "0#{@middle.id}", "bad" ].join("|")
    get root_path
    assert_select "details[data-group=?]:not([open])", @top.id.to_s
    assert_select "details[data-group=?][open]", @middle.id.to_s
    assert_select "details[data-group=?]", @leaf.id.to_s, count: 0
    assert_select "details[data-group=?]", @foreign.id.to_s, count: 0

    cookies[:collapsed_agents] = "#{@top.id}|#{'9' * 1920}"
    get root_path
    assert_select "details[data-group=?][open]", @top.id.to_s
  end

  test "even an older release that left a dangling or cross-workspace parent cannot hide an agent" do
    [ 999_999, @foreign.id ].each do |invalid_id|
      @middle.update_columns(parent_id: invalid_id)
      get root_path
      assert_select "#group_workspace_#{@team.id} .tree > .tree-branch > .tree-row > #row_conversation_#{@middle.conversation.id}"
      assert_select "#row_conversation_#{@middle.conversation.id}", text: /Rill/
    end
  end

  test "a manager agent gets no thread access and cannot answer its report's card" do
    @leaf.update!(parent_id: @middle.id)
    report = create_conversation(@leaf, durable_id: "report")
    manager = create_conversation(@middle, durable_id: "manager")
    card = report.invocations.create!(task_id: "7", call_id: "c", tool_name: "change_yourself", arguments: { "instructions" => "Change" },
      digest: "digest", state: "awaiting_person", expires_at: 1.day.from_now)

    unsigned = open_session
    unsigned.post conversation_invocation_approval_path(report, card), params: { decision: "approve" }, headers: rails_bearer, as: :json
    assert_equal 401, unsigned.response.status
    unsigned.get conversation_path(report), headers: rails_bearer
    assert_equal 303, unsigned.response.status
    assert_equal sign_in_path, URI(unsigned.response.location).path

    tool = Tool::WithdrawCard.new(manager.invocations.new(tool_name: "withdraw_card"))
    assert_raises(Tool::Refusal) { tool.call(card_id: card.id) }
    assert card.reload.awaiting_person?
    assert_nil card.approval
  end

  private
    def move(agent, to:)
      patch agent_reporting_path(agent), params: { reporting: { parent_id: to&.id.to_s } }
    end
end
