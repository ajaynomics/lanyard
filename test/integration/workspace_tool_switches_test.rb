require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/email_test_helper"

class WorkspaceToolSwitchesTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include EmailTestHelper

  EMAIL = { "to" => [ "robin@example.com" ], "subject" => "Friday", "body" => "Two nights." }.freeze

  setup do
    install_sidecar_settings
    install_email_settings
    sign_in_via_ajent(name: "Owner")
    @owner = User.find_by!(oidc_sub: "42") # tenancy-ok: the test reads the person it signed in
    @workspace = Workspace.make(name: "Orchard", owner: @owner)
    @agents = [ make_agent(@workspace, "Juniper"), make_agent(@workspace, "Rowan") ]
    @other = @owner.personal_workspace.agents.sole
  end

  teardown do
    remove_email_settings
    remove_sidecar_settings
  end

  test "switching off a tool removes it from every agent's definition in only that workspace" do
    assert_tool_off @agents.first, "send_email", false
    @workspace.update!(disabled_tools: [ "send_email", "list_documents" ])

    @agents.each { assert_tool_off it, "send_email", true }
    @agents.each { assert_tool_off it, "list_documents", true }
    assert_tool_off @other, "send_email", false
    assert_tool_off @other, "list_documents", false

    reply = receive(@agents.first, "send_email", EMAIL, "off")
    assert reply.failed?
    assert_match "not one of this agent's tools", reply.error
  end

  test "each workspace send asks despite a recipient grant and an approve-everything policy" do
    @workspace.update!(asks_every: [ "send_email" ], approval_policy: "everything")
    @agents.each do |agent|
      grant = grant_email(agent)
      invocation = receive(agent, "send_email", EMAIL, "workspace")
      assert invocation.awaiting_person?
      assert_match "so this asks every time.", invocation.approval_note
      assert_empty invocation.always_choices
      assert_raises(ArgumentError) { invocation.approve!(by: @owner, always: "recipient") }
      assert invocation.reload.awaiting_person?
      assert_equal grant.id, agent.permissions.sole.id
    end

    grant_email(@other)
    assert receive(@other, "send_email", EMAIL, "other").running?

    @workspace.update!(asks_every: [])
    assert receive(@agents.first, "send_email", EMAIL, "unlocked").running?
  end

  test "install lists apply to every workspace even when workspace and agent switches are unset" do
    with_setting(:app, :disabled_tools, %w[ current_time list_documents ]) do
      with_setting(:app, :asks_every, %w[ send_text send_email ]) do
        [ @agents.first, @other ].each do |agent|
          assert_tool_off agent, "current_time", true
          assert_tool_off agent, "list_documents", true
          grant = grant_email(agent)
          assert receive(agent, "send_email", EMAIL, "install").awaiting_person?
          assert_equal grant.id, agent.permissions.sole.id
        end
      end
    end
  end

  test "a workspace asks for Concourse replies under the Concourse send switch" do
    @workspace.update!(asks_every: [ "concourse_send" ])
    reply = Tool::ConcourseReply.new(@agents.first.conversation.invocations.build(tool_name: "concourse_reply"))
    assert reply.asks_every_send?
    assert_equal :approval, reply.asks
  end

  test "workspace ask switches accept only the four sending names" do
    @workspace.asks_every = [ "concourse_reply", "current_time" ]
    assert_not @workspace.valid?
    assert @workspace.errors[:asks_every].any?
  end

  test "owner changes an individual workspace switch and a member cannot" do
    get workspace_path(@workspace)
    assert_select "#workspace_asks_every_send_email:not([checked])"
    assert_select "#workspace_disabled_send_email:not([checked])"

    patch switch_path, params: { tool: "send_email", setting: "asks_every", on: "1" }
    assert_redirected_to workspace_path(@workspace)
    assert_equal [ "send_email" ], @workspace.reload.asks_every

    patch switch_path, params: { tool: "current_time", setting: "disabled_tools", on: "1" }
    assert_redirected_to workspace_path(@workspace)
    assert_equal [ "current_time" ], @workspace.reload.disabled_tools

    member = create_user(name: "Casey")
    @workspace.memberships.create!(user: member, role: "member")
    sign_in_via_ajent(subject: member.oidc_sub, email: member.email, name: member.name)
    get workspace_path(@workspace)
    assert_response :success
    assert_select "#tool_switches", count: 0
    patch switch_path, params: { tool: "send_email", setting: "asks_every", on: "0" }
    assert_response :not_found
    assert_equal [ "send_email" ], @workspace.reload.asks_every
  end

  test "agent cannot untick workspace switches through either settings endpoint" do
    agent = @agents.first
    @workspace.update!(disabled_tools: [ "send_email" ], asks_every: [ "send_email" ])
    agent.update!(asks_every_email: true, disabled_tools: [ "send_email" ])

    get agent_tools_path(agent)
    assert_select "#tool_send_email[checked][disabled]"
    assert_select ".ui-row", text: /Send email.*Set for Orchard/mi
    patch agent_tool_path(agent, "send_email"), params: { on: "1" }
    assert_redirected_to agent_tools_path(agent)
    assert_match "set for Orchard", flash[:alert]
    assert_equal [ "send_email" ], agent.reload.disabled_tools

    get agent_permissions_path(agent)
    assert_select "#agent_asks_every_email[checked][disabled]"
    assert_select ".ui-row", text: /Ask before every email.*Set for Orchard/m
    patch agent_path(agent), params: { agent: { asks_every_email: "0" } }
    assert_redirected_to agent_permissions_path(agent)
    assert_match "set for Orchard", flash[:alert]
    assert agent.reload.asks_every_email?
  end

  test "install locks workspace and agent switches without saving local copies" do
    agent = @agents.first
    with_setting(:app, :disabled_tools, [ "send_email" ]) do
      with_setting(:app, :asks_every, [ "send_email" ]) do
        get workspace_path(@workspace)
        assert_select "#workspace_disabled_send_email[checked][disabled]"
        assert_select "#workspace_asks_every_send_email[checked][disabled]"
        assert_select "#tool_switches .ui-row__note", text: "Set for this install", count: 2

        patch switch_path, params: { tool: "send_email", setting: "disabled_tools", on: "0" }
        assert_redirected_to workspace_path(@workspace)
        assert_match "set for this install", flash[:alert]
        assert_empty @workspace.reload.disabled_tools

        patch agent_tool_path(agent, "send_email"), params: { on: "1" }
        assert_match "set for this install", flash[:alert]
        patch agent_tool_path(agent, "send_email"), params: { on: "0" }
        assert_match "set for this install", flash[:alert]
        assert_empty agent.reload.disabled_tools
        patch agent_path(agent), params: { agent: { asks_every_email: "0" } }
        assert_match "set for this install", flash[:alert]
        assert_not agent.reload.asks_every_email?
      end
    end

    get agent_tools_path(agent)
    assert_select "#tool_send_email[checked]:not([disabled])"
    patch agent_tool_path(agent, "send_email"), params: { on: "0" }
    assert_equal [ "send_email" ], agent.reload.disabled_tools
    assert_tool_off agent, "send_email", true
    assert_tool_off @agents.last, "send_email", false
  end

  private
    def switch_path = workspace_tool_switches_path(@workspace)

    def make_agent(workspace, name)
      workspace.agents.create!(user: @owner, name: name, instructions: "Help.", model: Agent.models.first,
        tool_names: %w[ current_time ], capabilities: %w[ codemode ])
    end

    def assert_tool_off(agent, name, off)
      agent.reload
      assert_equal !off, agent.own_tools.any? { it.tool_name == name }, "#{agent}: #{name} in own tools"
      definition = agent.conversation.definition
      names = (definition.fetch(:tools) + definition.fetch(:lookup, [])).pluck(:name)
      assert_equal !off, names.include?(name), "#{agent}: #{name} in definition"
      assert_equal !off, agent.conversation.tool(name).present?, "#{agent}: #{name} callable"
    end

    def grant_email(agent) = agent.permissions.create!(tool_name: "send_email", recipient: EMAIL["to"].sole, granted_by: @owner)

    def receive(agent, tool, arguments, call_id)
      conversation = agent.reload.conversation
      payload = invocation_payload(conversation, tool:, arguments:, call_id:)
      Invocation.receive(conversation, task_id: payload[:taskId], call_id:, tool:, arguments:, digest: payload[:digest])
      conversation.invocations.find_by!(call_id:)
    end
end
