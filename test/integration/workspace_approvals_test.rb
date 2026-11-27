require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/voipms_test_helper"
require_relative "../test_helpers/passbolt_test_helper"

# Each workspace's own approval policy (#226), set by its owner on its page;
# the install's (APP__APPROVE_EVERYTHING, APP__APPROVALS) is only the default
# for a workspace that has chosen none. On the normal policy what reaches
# another person asks first, and so do a change to the agent itself and
# removing a routine; what asks even where everything is approved asks
# everywhere.
class WorkspaceApprovalsTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include VoipmsTestHelper
  include PassboltTestHelper
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
      phone_number: "6475550123", own_instruction_approval: false, tool_names: %w[ forget_note ])
    # B: a household the owner shares, on the normal policy.
    @b = Workspace.make(name: "Household", owner: @owner)
    @b.memberships.create!(user: @member, role: "member")
    @b.update!(approval_policy: "others")
    @b_agent = @b.agents.create!(user: @owner, name: "Bea", instructions: "Help.", model: Agent.models.first,
      phone_number: "6475550124", tool_names: %w[ forget_note ])
    @a = create_conversation(@a_agent, durable_id: "a1")
    @b_conversation = create_conversation(@b_agent, durable_id: "b1")
  end

  teardown do
    remove_voipms_settings
    remove_fake_passbolt
    remove_sidecar_settings
  end

  test "where the install approves everything, a text asks in a workspace on the normal policy and not in one left on the default" do
    with_setting(:app, :approve_everything, true) do
      assert receive(@b_conversation, "send_text", TEXT, "b-text").awaiting_person?, "B is on the normal policy"
      assert_equal "running", receive(@a, "send_text", TEXT, "a-text").state, "A is on the install's default"
    end
  end

  test "own-instruction approval is separate from the workspace's normal policy" do
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

  test "in a workspace the install names, wake timers are added and removed without a card; elsewhere they still ask" do
    routine = @b_agent.routines.create!(schedule: "every day at 9am", prompt: "Check.")
    with_setting(:app, :routines_unasked_workspaces, [ @a_agent.workspace_id.to_s, @b.id.to_s ]) do
      assert_not receive(@a, "add_routine", { "schedule" => "every day at 8am", "prompt" => "Brief me." }, "a-add").awaiting_person?
      assert_not receive(@b_conversation, "remove_routine", { "id" => routine.id }, "b-remove").awaiting_person?
    end
    assert_equal [ "every day at 8am" ], @a_agent.routines.map(&:schedule)
    assert_not @b_agent.routines.exists?(routine.id)
    with_setting(:app, :routines_unasked_workspaces, [ @b.id.to_s ]) do
      assert receive(@a, "add_routine", { "schedule" => "every day at 7am", "prompt" => "Brief me." }, "a-add-2").awaiting_person?
    end
  end

  test "a workspace's own choice holds whatever the install's default; without one, the default" do
    @b.update!(approval_policy: "everything")
    assert_equal "running", receive(@b_conversation, "send_text", TEXT, "b-text").state
    assert receive(@a, "send_text", TEXT, "a-text").awaiting_person?
  end

  {
    "pay_by_card" => [ :payment, { "amount" => 2450, "currency" => "usd", "payee" => "Books",
      "checkout_url" => "https://shop.example/checkout", "reason" => "Two books the person asked for." } ],
    "ask_for_sign_in" => [ :sign_in, { "name" => "Bank", "site" => "https://bank.example/login" } ],
    "ask_outside_for_sign_in" => [ :approval, { "name" => "Bank" } ],
    "sign_in_with_saved_password" => [ :approval, { "name" => "Bank" } ],
    "call_api_with_saved_key" => [ :approval, { "name" => "Bank", "method" => "GET", "path" => "/status" } ]
  }.each do |name, (kind, arguments)|
    test "#{name} still shows its card when the workspace switches to Approve everything" do
      with_credential_tools do
        assert receive(@b_conversation, name, arguments, "before").awaiting_person?
        @b.update!(approval_policy: "everything")
        assert_credential_card(name, kind, arguments)
      end
    end

    test "#{name} still shows its card for an agent the install names to approve everything" do
      with_credential_tools do
        with_setting(:app, :owner_approval_agents, [ "bea" ]) { assert_credential_card(name, kind, arguments) }
      end
    end

    test "#{name} still shows its card when the install allows everything" do
      with_credential_tools do
        @b.update!(approval_policy: nil)
        with_setting(:app, :approvals, "allow") { assert_credential_card(name, kind, arguments) }
      end
    end
  end

  test "an agent the install names approves everything, with no built-in approval block; the rest of its workspace keep their cards; other workspaces are unchanged" do
    cal = @b.agents.create!(user: @owner, name: "Cal", instructions: "Help.", model: Agent.models.first, phone_number: "6475550125",
      tool_names: %w[ forget_note ])
    dee = @b.agents.create!(user: @owner, name: "Dee", instructions: "Help.", model: Agent.models.first, phone_number: "6475550126")
    cal_conversation, dee_conversation = create_conversation(cal, durable_id: "c1"), create_conversation(dee, durable_id: "d1")
    cal.notes.remember("old", "x")
    heading = "**Approvals.**"

    with_setting(:app, :approve_everything, true) do
      with_setting(:app, :owner_approval_agents, [ "bea" ]) do
        assert_equal "running", receive(@b_conversation, "send_text", TEXT, "b-text").state, "the named agent approves everything"
        assert_not_includes @b_agent.reload.conversation.definition[:instructions], heading, "its own instructions say how it asks its owner"
        [ [ cal_conversation, "c-text" ], [ dee_conversation, "d-text" ] ].each do |conversation, call_id|
          assert receive(conversation, "send_text", TEXT, call_id).awaiting_person?, "its workspace's other agents keep their cards"
          assert_not_includes conversation.agent.reload.conversation.definition[:instructions], heading
        end
        assert receive(cal_conversation, "change_yourself", { "instructions" => "Be brief." }, "c-change").awaiting_person?
        assert receive(cal_conversation, "forget_note", { "key" => "old" }, "c-forget").succeeded?, "what reaches no one runs"

        assert_equal "running", receive(@a, "send_text", TEXT, "a-text").state, "another workspace is as before"
        assert_not_includes @a_agent.reload.conversation.definition[:instructions], heading
        get agent_permissions_path(@b_agent)
        assert_select ".ui-group__help", text: /This install approves everything/
        get agent_permissions_path(cal)
        assert_select ".ui-group__help", text: /Its workspace asks first before what reaches other people/
      end
      assert receive(@b_conversation, "send_text", TEXT, "b-text-unset").awaiting_person?, "unnamed, it follows its workspace"
      assert_not_includes @b_agent.reload.conversation.definition[:instructions], heading
    end
  end

  test "a name the install lists is never given to a new agent, so a deleted one's can't pass to someone else's" do
    with_setting(:app, :owner_approval_agents, [ "kit" ]) do
      other = create_user(name: "Stranger", email: "stranger@example.com")
      taken = other.personal_workspace.agents.build(user: other, name: "Kit", email_name: "kit", instructions: "Help.", model: Agent.models.first)
      assert_not taken.save
      assert_includes taken.errors[:email_name], "is kept for an agent the install names to approve everything"

      named = other.personal_workspace.agents.create!(user: other, name: "Kit", instructions: "Help.", model: Agent.models.first)
      assert_equal "kit-2", named.email_name, "a name made from Kit skips the listed one"
      assert_not named.approvals.everything?, "and follows its workspace"
    end
  end

  test "a saved key's Always lets later calls with that key run under either switch, and another key still asks" do
    with_credential_tools do
      key = { "name" => "Bank", "method" => "GET", "path" => "/status" }
      other = key.merge("name" => "Builds")
      @b_agent.permissions.create!(tool_name: "call_api_with_saved_key", recipient: "Bank", granted_by: @owner)
      @b.update!(approval_policy: "everything")
      assert_not receive(@b_conversation.reload, "call_api_with_saved_key", key, "granted").awaiting_person?
      assert receive(@b_conversation, "call_api_with_saved_key", other, "other").awaiting_person?
      @b.update!(approval_policy: nil)
      with_setting(:app, :approvals, "allow") do
        assert_not receive(@b_conversation.reload, "call_api_with_saved_key", key, "granted-allow").awaiting_person?
        assert receive(@b_conversation, "call_api_with_saved_key", other, "other-allow").awaiting_person?
      end
    end
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
    def with_credential_tools
      install_fake_passbolt
      @b_agent.create_computer!(provider: "sprites", state: "on")
      @b_agent.update!(tool_names: @b_agent.tool_names | %w[ pay_by_card call_api_with_saved_key ])
      @owner.update!(link_session: { "refresh_token" => "test-link-token" })
      with_setting(:link, :client_id, "lwlpk_example") { yield }
    end

    def assert_credential_card(name, kind, arguments)
      invocation = receive(@b_conversation.reload, name, arguments, "after")
      assert_equal "awaiting_person", invocation.state
      assert_equal kind, invocation.asks
      if name == "call_api_with_saved_key"
        assert_equal [ "recipient" ], invocation.always_choices
      else
        assert_empty invocation.always_choices
      end
      assert @b_conversation.tool(name).every_time? if kind == :approval
    end

    def receive(conversation, tool, arguments, call_id)
      payload = invocation_payload(conversation, tool: tool, arguments: arguments, call_id: call_id)
      Invocation.receive(conversation, task_id: payload[:taskId], call_id: call_id, tool: tool, arguments: arguments, digest: payload[:digest])
      conversation.invocations.find_by!(call_id: call_id)
    end
end
