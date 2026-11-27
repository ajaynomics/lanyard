require "test_helper"
require_relative "../test_helpers/agent_test_helper"

class SelfInstructionPermissionsTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: the signed-in person's agent
    @conversation = create_conversation(@agent)
    @before = @agent.instructions
    @next_call = 0
  end

  teardown { remove_sidecar_settings }

  test "an old opt-out under broad install approval still needs a card until explicitly enabled" do
    @agent.class.with_connection do |connection|
      connection.update("UPDATE agents SET asks_every_instruction_change = 0 WHERE id = #{@agent.id}")
    end
    with_setting(:app, :approvals, "allow") do
      assert change("Help the gardener.").awaiting_person?
    end
    assert_equal @before, @agent.reload.instructions
  end

  test "the most specific explicit setting wins without changing the workspace's approval policy" do
    Dir.mktmpdir("instruction-permissions") do |directory|
      with_setting(:app, :instruction_changes_path, Pathname(directory).join("setting")) do
        assert change("Help the gardener.").awaiting_person?

        DurableAssistants.own_instruction_approval = false
        assert change("Help the librarian.", scope: "yourself").succeeded?
        assert_equal "Help the librarian.", @agent.reload.instructions

        @agent.workspace.update!(own_instruction_approval: true)
        assert change("Help the painter.").awaiting_person?

        @agent.update!(own_instruction_approval: false)
        assert change("Help the baker.").succeeded?

        @agent.workspace.update!(own_instruction_approval: false)
        @agent.update!(own_instruction_approval: true)
        assert change("Help the tailor.").awaiting_person?

        @agent.update!(own_instruction_approval: nil)
        assert change("Help the potter.").succeeded?
        assert_equal "Help the potter.", @agent.reload.instructions
        assert change("Keep the studio tidy.", scope: "workspace").awaiting_person?
      end
    end
  end

  test "a member without install admin access cannot change the setting at any level" do
    with_setting(:access, :admins, []) do
      get agent_permissions_path(@agent)
      assert_select "#instruction_change_permissions", /Approval required/
      assert_select "#instruction_change_permissions form", count: 0

      patch settings_instruction_approval_path, params: { app: { own_instruction_approval: "0" } }
      assert_response :not_found
      patch workspace_path(@agent.workspace), params: { workspace: { own_instruction_approval: "0" } }
      assert_response :not_found
      patch agent_path(@agent), params: { agent: { own_instruction_approval: "0" } }
      assert_response :not_found
    end
    assert_nil @agent.reload.own_instruction_approval
    assert_nil @agent.workspace.reload.own_instruction_approval
  end

  private
    def change(instructions, **arguments)
      contents = { "instructions" => instructions }.merge(arguments.stringify_keys)
      call_id = "change_#{@next_call += 1}"
      @conversation.reload
      payload = invocation_payload(@conversation, tool: "change_yourself", arguments: contents, call_id: call_id)
      Invocation.receive(@conversation, task_id: payload[:taskId], call_id: call_id, tool: "change_yourself",
        arguments: contents, digest: payload[:digest])
      @conversation.invocations.find_by!(call_id: call_id)
    end
end
