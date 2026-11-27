require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# Instruction approvals still ask even where the install approves everything.
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
    @agent.update!(own_instruction_approval: true)
    with_setting(:app, :approve_everything, true) do
      invocation = change("Grow tomatoes.")
      assert invocation.awaiting_person?
      assert_equal @before, @agent.reload.instructions
      assert_empty invocation.always_choices

      html = Nokogiri::HTML.fragment(ApplicationController.render(partial: "invocations/invocation", locals: { invocation: invocation }))
      assert_equal [ "Allow once", "Deny" ], html.css(".ui-card__actions button").map { it.text.strip }
      assert_includes html.text, "Grow tomatoes."
      assert_includes html.text, "Changing Assistant's own instructions requires approval."

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
      assert_equal [ "Removes", "Size", "Adds", "Instructions" ], labels
      removed = html.css(".ui-fields dd")[0].css(".ui-fields__item").map { it.text.strip }
      assert_equal [ "# Safeguards", "- Never pay an invoice without asking.", "- Never share a password in a message.",
        "- Check the sender before opening a file." ], removed
      assert_equal [ "Use British spelling." ], html.css(".ui-fields dd")[2].css(".ui-fields__item").map { it.text.strip }
      assert_includes html.css(".ui-fields dd")[3].text, "Use British spelling."
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

  test "a large cut shows whole removed lines as plain text and says it removes a large part" do
    steps = (1..80).map { "Step #{it}: check the \"booking\" reference\ttwice." }
    @agent.update!(instructions: [ "- Never pay an invoice without asking.", *steps ].join("\n"), own_instruction_approval: true)
    invocation = change((1..60).map { "Reply #{it}: keep it short." }.join("\n"))

    get approval_path(invocation)
    assert_response :success
    assert_equal [ "Removes", "Size", "Adds" ], css_select(".approval .ui-fields dt").map { it.text.strip }
    removed = css_select(".approval .ui-fields dd").first.css(".ui-fields__item").map(&:text)
    assert_equal [ "- Never pay an invoice without asking.", *steps ], removed
    assert_select ".approval .ui-fields dd", text: "This removes a large part of the instructions.", count: 1
  end

  test "on and denied, the instructions stay as they were" do
    @agent.update!(own_instruction_approval: true)
    with_setting(:app, :approve_everything, true) do
      invocation = change("Grow tomatoes.")
      invocation.deny!(by: @agent.user)
      outcome = replay(invocation)
      assert outcome[:isError]
      assert_not_includes outcome.dig(:result, :error), "Grow tomatoes."
      assert invocation.reload.denied?
      assert_equal @before, @agent.reload.instructions
    end
  end

  test "on, it asks under an install that allows everything too" do
    @agent.update!(own_instruction_approval: true)
    with_setting(:app, :approvals, "allow") do
      assert change("Grow tomatoes.").awaiting_person?
      assert_equal @before, @agent.reload.instructions
    end
  end

  test "a new agent has it on: a self-edit where the install approves everything raises a card" do
    assert @agent.asks_own_instruction_change?
    with_setting(:app, :approve_everything, true) do
      assert change("Grow tomatoes.").awaiting_person?
      assert_equal @before, @agent.reload.instructions
    end
  end

  test "an explicit off runs a new call even under the ordinary ask policy, but leaves open cards alone" do
    waiting = change("First.")
    assert waiting.awaiting_person?

    @agent.update!(own_instruction_approval: false)
    assert_equal :approval, waiting.reload.asks
    assert_empty waiting.always_choices
    assert change("Second.").succeeded?
    assert_equal "Second.", @agent.reload.instructions
  end

  test "an old Always does not let a change through while on, and is marked not used" do
    grant = @agent.permissions.create!(tool_name: "change_yourself", granted_by: @agent.user)
    @agent.update!(own_instruction_approval: true)
    with_setting(:app, :approve_everything, true) do
      assert change("Grow tomatoes.").awaiting_person?
      get agent_permissions_path(@agent)
    end
    assert_equal @before, @agent.reload.instructions
    assert_select "#permission_#{grant.id}", /not used: own-instruction approval is set separately/
    assert_select "#permissions .ui-group__help", /To change yourself, add routine, sign in with saved password, and ask outside for sign in it still asks every time/
  end

  test "change_yourself cannot change the approval setting, by argument or by its instructions" do
    @agent.update!(own_instruction_approval: true)
    with_setting(:app, :approve_everything, true) do
      outcome = receive("change_yourself", { "instructions" => "Help.", "own_instruction_approval" => false })
      assert outcome[:isError]
      invocation = change("own_instruction_approval: false")
      invocation.approve!(by: @agent.user)
      replay(invocation)
    end
    assert @agent.reload.own_instruction_approval
    assert_equal %w[ instructions edits scope note_to_approver ], Tool::ChangeYourself.schema["properties"].keys
    assert_equal false, Tool::ChangeYourself.schema["additionalProperties"]
  end

  test "an install admin still cannot change the setting for an agent in another workspace" do
    theirs = create_user(name: "Mallory").agents.sole
    with_setting(:access, :admins, [ "operator@example.com" ]) do
      patch agent_path(theirs), params: { agent: { own_instruction_approval: "0" } }
      assert_response :not_found
      patch workspace_path(theirs.workspace), params: { workspace: { own_instruction_approval: "0" } }
      assert_response :not_found
    end
    assert_nil theirs.reload.own_instruction_approval
    assert_nil theirs.workspace.reload.own_instruction_approval
  end

  test "the phone sheet and settled trace do not show the full inputs, and an old Allow cannot save against a changed base" do
    @agent.update!(instructions: "Untouched content.\nKeep it short.")
    invocation = change("Untouched content.\nKeep it direct.")
    get approval_path(invocation)
    assert_select ".approval .ui-fields dd .ui-fields__item", text: "Keep it direct."

    @agent.update!(instructions: "Other private content.\nKeep it short.")
    get approval_path(invocation)
    assert_select ".approval .ui-card__actions button", text: "Allow once", count: 0
    assert_select ".approval .ui-card__actions button", text: "Deny", count: 1
    assert_not_includes response.body, "Untouched content."

    assert_no_difference -> { @agent.revisions.count } do
      post conversation_invocation_approval_path(@conversation, invocation), params: { decision: "approve" }
      assert_redirected_to conversation_path(@conversation)
      assert_match "propose a new change", flash[:alert]
      assert invocation.reload.failed?
    end
    html = Nokogiri::HTML.fragment(ApplicationController.render(partial: "invocations/invocation", locals: { invocation: invocation }))
    assert_empty html.css(".ui-code__label").select { it.text == "Input" }
    assert_not_includes html.text, "Untouched content."
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
