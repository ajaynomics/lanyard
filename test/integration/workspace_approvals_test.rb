require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/voipms_test_helper"

# Each workspace's own approval policy (#226), set by its owner on its page;
# the install's (APP__APPROVE_EVERYTHING, APP__APPROVALS) is only the default
# for a workspace that has chosen none. On the normal policy what reaches
# another person asks first, and so do a change to the agent itself and
# removing a routine; what asks even where everything is approved asks
# everywhere.
class WorkspaceApprovalsTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include VoipmsTestHelper
  include ActiveJob::TestHelper

  TEXT = { "to" => "4165550199", "body" => "Your parcel is here." }.freeze

  # What a tool looks like to Agent#allows? when it asks every time but an
  # instance override left "Always" on (as Tool::AsksEverySend's switch would,
  # had it not also turned always? off). Only the guard in allows? stops a
  # stored Always from covering it.
  EveryTimeTool = Data.define(:permission_name) do
    def always? = true
    def every_time? = true
    def even_approving_everything? = false
    def always_with_recipients? = false
    def reaches_others? = false
    def changes_itself? = false
    def recipients = []
  end

  setup do
    install_sidecar_settings
    install_voipms_settings
    stub_voipms
    sign_in_via_ajent(name: "Owner")
    @owner = User.find_by!(oidc_sub: "42") # tenancy-ok: test reads the person it signed in
    @member = create_user(name: "Bob", email: "member@example.com")
    # A: the owner's own workspace, on the install's default.
    @a_agent = @owner.personal_workspace.agents.create!(user: @owner, name: "Ada", instructions: "Help.", model: Agent.models.first,
      phone_number: "6475550123", asks_every_instruction_change: false, tool_names: %w[ forget_note ])
    # B: a household the owner shares, on the normal policy.
    @b = Workspace.make(name: "Household", owner: @owner)
    @b.memberships.create!(user: @member, role: "member")
    @b.update!(approval_policy: "others")
    @b_agent = @b.agents.create!(user: @owner, name: "Bea", instructions: "Help.", model: Agent.models.first,
      phone_number: "6475550124", asks_every_instruction_change: false, tool_names: %w[ forget_note ])
    @a = create_conversation(@a_agent, durable_id: "a1")
    @b_conversation = create_conversation(@b_agent, durable_id: "b1")
  end

  teardown do
    remove_voipms_settings
    remove_sidecar_settings
  end

  test "where the install approves everything, a text asks in a workspace on the normal policy and not in one left on the default" do
    with_setting(:app, :approve_everything, true) do
      assert receive(@b_conversation, "send_text", TEXT, "b-text").awaiting_person?, "B is on the normal policy"
      assert_equal "running", receive(@a, "send_text", TEXT, "a-text").state, "A is on the install's default"
    end
  end

  test "on the normal policy a change to the agent itself and removing a routine ask; what reaches no one does not" do
    routine = @b_agent.routines.create!(schedule: "every day at 8am", prompt: "Brief me.")
    @b_agent.notes.remember("old", "x")
    with_setting(:app, :approve_everything, true) do
      assert receive(@b_conversation, "change_yourself", { "instructions" => "Be brief." }, "b-change").awaiting_person?
      assert receive(@b_conversation, "remove_routine", { "id" => routine.id }, "b-remove").awaiting_person?
      assert receive(@b_conversation, "forget_note", { "key" => "old" }, "b-forget").succeeded?, "it reaches no one"

      assert receive(@a, "change_yourself", { "instructions" => "Be brief." }, "a-change").succeeded?
    end
    assert_equal "Help.", @b_agent.reload.instructions
    assert @b_agent.routines.exists?(routine.id)
  end

  test "what asks even where everything is approved asks in a workspace on the default too" do
    with_setting(:app, :approve_everything, true) do
      assert receive(@a, "add_routine", { "schedule" => "every day at 8am", "prompt" => "Brief me." }, "a-add").awaiting_person?
    end
    assert_empty @a_agent.routines
  end

  test "a workspace's own choice holds whatever the install's default; without one, the default" do
    @b.update!(approval_policy: "everything")
    assert_equal "running", receive(@b_conversation, "send_text", TEXT, "b-text").state
    assert receive(@a, "send_text", TEXT, "a-text").awaiting_person?
  end

  test "a stored Always never lets a call that asks every time go unasked, but approving everything still does" do
    @b_agent.permissions.create!(tool_name: "every_time_tool", recipient: "", granted_by: @owner)
    tool = EveryTimeTool.new("every_time_tool")

    assert_not @b_agent.allows?(tool), "on the normal policy"
    @b.update!(approval_policy: nil)
    assert_not @b_agent.reload.allows?(tool), "on the install's default, asking"
    with_setting(:app, :approvals, "allow") { assert_not @b_agent.reload.allows?(tool), "on the install's default, allowing" }
    @b.update!(approval_policy: "everything")
    assert @b_agent.reload.allows?(tool), "approving everything runs it, as it always has"

    @b_agent.permissions.create!(tool_name: "imessage_send", recipient: "", granted_by: @owner)
    @b.update!(approval_policy: "others")
    assert_not @b_agent.reload.allows?(Tool::ImessageSend.new(@b_conversation.invocations.new(tool_name: "imessage_send"))), "a real iMessage, on the normal policy"
  end

  test "an owner has three choices: the install's default, ask before what reaches other people, approve everything" do
    get workspace_path(@b)
    assert_equal [ "", "others", "everything" ], css_select("#approval_policy select option").map { it["value"] }

    [ nil, "others", "everything" ].each do |choice|
      @b.approval_policy = choice
      assert @b.valid?, "#{choice.inspect} is a choice"
    end
    @b.approval_policy = "ask"
    assert_not @b.valid?, "stricter than the normal policy is no workspace's choice"
    assert @b.errors.of_kind?(:approval_policy, :inclusion)

    patch workspace_approval_policy_path(@b), params: { workspace: { approval_policy: "ask" } }
    assert_response :unprocessable_entity
    assert_equal "others", @b.reload.approval_policy
  end

  test "its owner chooses the policy on the workspace's page; a member sees it and cannot change it" do
    get workspace_path(@b)
    assert_select "#approval_policy select[name='workspace[approval_policy]']"
    patch workspace_approval_policy_path(@b), params: { workspace: { approval_policy: "everything" } }
    assert_redirected_to workspace_path(@b)
    assert_equal "everything", @b.reload.approval_policy
    patch workspace_approval_policy_path(@b), params: { workspace: { approval_policy: "whatever" } }
    assert_response :unprocessable_entity
    patch workspace_approval_policy_path(@b), params: { workspace: { approval_policy: "" } }
    assert_nil @b.reload.approval_policy, "back to the install's default"

    get workspace_path(@owner.personal_workspace)
    assert_select "#approval_policy select[name='workspace[approval_policy]']", 1, "a personal workspace has one too"

    @b.update!(approval_policy: "others")
    sign_in_via_ajent(subject: "sub-bob", email: "member@example.com", name: "Bob")
    get workspace_path(@b)
    assert_response :success
    assert_select "#approval_policy form", count: 0
    assert_select "#approval_policy", /what reaches other people/
    patch workspace_approval_policy_path(@b), params: { workspace: { approval_policy: "everything" } }
    assert_response :not_found
    assert_equal "others", @b.reload.approval_policy
  end

  test "an agent's Permissions says its workspace's policy, or the install's where it chose none" do
    with_setting(:app, :approve_everything, true) do
      get agent_permissions_path(@b_agent)
      assert_select ".ui-group__help", text: /Its workspace asks first before what reaches other people: [^.]*send text/
      get agent_permissions_path(@a_agent)
      assert_select ".ui-group__help", text: /This install approves everything/
      @owner.personal_workspace.update!(approval_policy: "everything")
      get agent_permissions_path(@a_agent)
      assert_select ".ui-group__help", text: /Its workspace approves everything/
    end
  end

  private
    def receive(conversation, tool, arguments, call_id)
      payload = invocation_payload(conversation, tool: tool, arguments: arguments, call_id: call_id)
      Invocation.receive(conversation, task_id: payload[:taskId], call_id: call_id, tool: tool, arguments: arguments, digest: payload[:digest])
      conversation.invocations.find_by!(call_id: call_id)
    end
end
