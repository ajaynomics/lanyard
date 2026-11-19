require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# The Permissions page's switch that makes change_yourself ask before every
# change to an agent's instructions, even where the install approves
# everything and whatever the person answered before.
class InstructionChangeApprovalsTest < ActionDispatch::IntegrationTest
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

  test "on, where the install approves everything, it asks, and the instructions change only once allowed" do
    @agent.update!(asks_every_instruction_change: true)
    with_setting(:app, :approve_everything, true) do
      invocation = change("Grow tomatoes.")
      assert invocation.awaiting_person?
      assert_equal @before, @agent.reload.instructions
      assert_empty invocation.always_choices

      html = Nokogiri::HTML.fragment(ApplicationController.render(partial: "invocations/invocation", locals: { invocation: invocation }))
      assert_equal [ "Allow once", "Deny" ], html.css(".ui-card__actions button").map { it.text.strip }
      assert_includes html.text, "Grow tomatoes."
      assert_includes html.text, "Assistant is set to ask before every change to its instructions, so this asks every time."

      invocation.approve!(by: @agent.user)
      assert_equal "done", replay(invocation)[:status]
      assert_equal "Grow tomatoes.", @agent.reload.instructions
    end
  end

  test "a self-edit that drops lines shows the person what it removes, above the new text" do
    @agent.update!(instructions: <<~TEXT)
      # Safeguards
      - Never pay an invoice without asking.
      - Never share a password in a message.
      - Check the sender before opening a file.

      Write short replies.
      Sign off with your name.
    TEXT
    with_setting(:app, :approve_everything, true) do
      invocation = change("Write short replies.\nSign off with your name.\nUse British spelling.")
      assert invocation.awaiting_person?

      html = Nokogiri::HTML.fragment(ApplicationController.render(partial: "invocations/invocation", locals: { invocation: invocation }))
      labels = html.css(".ui-fields dt").map { it.text.strip }
      assert_equal [ "Removes", "Adds", "Instructions" ], labels
      removed = html.css(".ui-fields dd")[0].css(".ui-fields__item").map { it.text.strip }
      assert_equal [ "# Safeguards", "- Never pay an invoice without asking.", "- Never share a password in a message.",
        "- Check the sender before opening a file." ], removed
      assert_equal [ "Use British spelling." ], html.css(".ui-fields dd")[1].css(".ui-fields__item").map { it.text.strip }
      assert_includes html.css(".ui-fields dd")[2].text, "Use British spelling."
    end
  end

  test "a self-edit that only adds says it removes nothing" do
    @agent.update!(instructions: "Write short replies.")
    with_setting(:app, :approve_everything, true) do
      invocation = change("Write short replies.\nUse British spelling.")
      assert_equal({ "removes" => "Nothing", "adds" => [ "Use British spelling." ], "instructions" => "Write short replies.\nUse British spelling." },
        invocation.details)
    end
  end

  test "on and denied, the instructions stay as they were" do
    @agent.update!(asks_every_instruction_change: true)
    with_setting(:app, :approve_everything, true) do
      invocation = change("Grow tomatoes.")
      invocation.deny!(by: @agent.user)
      assert replay(invocation)[:isError]
      assert invocation.reload.denied?
      assert_equal @before, @agent.reload.instructions
    end
  end

  test "on, it asks under an install that allows everything too" do
    @agent.update!(asks_every_instruction_change: true)
    with_setting(:app, :approvals, "allow") do
      assert change("Grow tomatoes.").awaiting_person?
      assert_equal @before, @agent.reload.instructions
    end
  end

  test "a new agent has it on: a self-edit where the install approves everything raises a card" do
    assert @agent.asks_every_instruction_change?
    with_setting(:app, :approve_everything, true) do
      assert change("Grow tomatoes.").awaiting_person?
      assert_equal @before, @agent.reload.instructions
    end
  end

  test "off is the behaviour from before: approve everything and allow everything run it, otherwise it asks with no Always" do
    @agent.update!(asks_every_instruction_change: false)
    with_setting(:app, :approve_everything, true) do
      assert change("First.").succeeded?
      assert_equal "First.", @agent.reload.instructions
    end
    with_setting(:app, :approvals, "allow") do
      assert change("Second.").succeeded?
      assert_equal "Second.", @agent.reload.instructions
    end
    invocation = change("Third.")
    assert invocation.awaiting_person?
    assert_empty invocation.always_choices
    assert_nil invocation.approval_note
    assert_equal "Second.", @agent.reload.instructions
  end

  test "an old Always does not let a change through while on, and is marked not used" do
    grant = @agent.permissions.create!(tool_name: "change_yourself", granted_by: @agent.user)
    @agent.update!(asks_every_instruction_change: true)
    with_setting(:app, :approve_everything, true) do
      assert change("Grow tomatoes.").awaiting_person?
      get agent_permissions_path(@agent)
    end
    assert_equal @before, @agent.reload.instructions
    assert_select "#permission_#{grant.id}", /not used: Assistant is set to ask before every change to its instructions/
    assert_select "#permissions .ui-group__help", /To change yourself, add routine, and ask outside for sign in it still asks every time/
  end

  test "the switch starts on, toggles on the Permissions page, and belongs to one agent" do
    other = @agent.user.personal_workspace.agents.create!(user: @agent.user, name: "Helper", instructions: "Help.", model: @agent.model)
    get agent_permissions_path(@agent)
    assert_select "#sending_approvals ~ .ui-group__rows input#agent_asks_every_instruction_change[role=switch][checked]", 1
    assert_select "label[for=agent_asks_every_instruction_change]", /Ask before every change to its instructions/

    patch agent_path(@agent), params: { agent: { asks_every_instruction_change: "0" } }, headers: { "HTTP_REFERER" => agent_permissions_url(@agent) }
    assert_redirected_to agent_permissions_path(@agent)
    assert_not @agent.reload.asks_every_instruction_change?
    assert other.reload.asks_every_instruction_change?
    assert_not @agent.asks_every_email?
    get agent_permissions_path(@agent)
    assert_select "input#agent_asks_every_instruction_change:not([checked])", 1

    patch agent_path(@agent), params: { agent: { asks_every_instruction_change: "1" } }, headers: { "HTTP_REFERER" => agent_permissions_url(@agent) }
    assert @agent.reload.asks_every_instruction_change?
  end

  test "change_yourself cannot turn the switch off, by argument or by its instructions" do
    @agent.update!(asks_every_instruction_change: true)
    with_setting(:app, :approve_everything, true) do
      outcome = receive("change_yourself", { "instructions" => "Help.", "asks_every_instruction_change" => false })
      assert outcome[:isError]
      invocation = change("asks_every_instruction_change: false")
      invocation.approve!(by: @agent.user)
      replay(invocation)
    end
    assert @agent.reload.asks_every_instruction_change?
    assert_equal %w[ instructions scope note_to_approver ], Tool::ChangeYourself.schema["properties"].keys
    assert_equal false, Tool::ChangeYourself.schema["additionalProperties"]
  end

  test "another person's agent's switch is not found" do
    theirs = create_user(name: "Mallory").agents.sole
    patch agent_path(theirs), params: { agent: { asks_every_instruction_change: "0" } }
    assert_response :not_found
    assert theirs.reload.asks_every_instruction_change?
  end

  private
    def change(instructions)
      outcome = receive("change_yourself", { "instructions" => instructions })
      @conversation.invocations.find_by!(call_id: outcome[:call_id])
    end

    def replay(invocation)
      receive(invocation.tool_name, invocation.arguments, call_id: invocation.call_id)
    end

    def receive(tool, arguments, call_id: "change_#{@next_call += 1}")
      @conversation.reload
      payload = invocation_payload(@conversation, tool: tool, arguments: arguments, call_id: call_id)
      Invocation.receive(@conversation, task_id: payload[:taskId], call_id: call_id, tool: tool,
        arguments: arguments, digest: payload[:digest]).deep_symbolize_keys.merge(call_id: call_id)
    end
end
