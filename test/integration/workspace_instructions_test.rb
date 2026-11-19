require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# A workspace's shared instructions: every one of its agents follows them,
# beside its own. Only its owner changes them: on the workspace page, by
# accepting a member's proposal there, or by allowing an agent's proposal
# (change_yourself with scope "workspace"), which waits for the owner even
# where the install approves everything.
class WorkspaceInstructionsTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  RULES = "Answer in British English.\nNever book travel without asking.".freeze

  setup do
    install_sidecar_settings
    @owner, @member = create_user(name: "Olive"), create_user(name: "Milo")
    @workspace = Workspace.create!(name: "Studio")
    @workspace.memberships.create!(user: @owner, role: "owner")
    @workspace.memberships.create!(user: @member, role: "member")
    @planner = @owner.start_agent("Planner", workspace: @workspace)
    @writer = @member.start_agent("Writer", workspace: @workspace)
    @elsewhere = create_user(name: "Nina").agents.sole
    @conversation = create_conversation(@planner)
    @next_call = 0
  end
  teardown { remove_sidecar_settings }

  test "an agent's proposal to its workspace's instructions waits for the owner, even where the install approves everything and its switch is off" do
    @workspace.change_instructions(RULES, by: @owner)
    @planner.update!(asks_every_instruction_change: false)
    with_setting(:app, :approve_everything, true) do
      invocation = propose("Answer in British English.\nKeep replies short.")
      assert invocation.awaiting_person?
      assert_equal RULES, @workspace.reload.instructions
      assert_empty invocation.always_choices

      html = Nokogiri::HTML.fragment(ApplicationController.render(partial: "invocations/invocation", locals: { invocation: invocation }))
      assert_equal "Change Studio's shared instructions?", html.at_css(".ui-card__title, h3, h2")&.text&.strip
      assert_equal [ "Removes", "Adds", "Instructions" ], html.css(".ui-fields dt").map { it.text.strip }
      assert_equal [ "Never book travel without asking." ], html.css(".ui-fields dd")[0].css(".ui-fields__item").map { it.text.strip }
      assert_equal [ "Keep replies short." ], html.css(".ui-fields dd")[1].css(".ui-fields__item").map { it.text.strip }
      assert_includes html.text, "Only Olive, its owner, can allow it."
    end
    with_setting(:app, :approvals, "allow") { assert propose("Anything.").awaiting_person? }
  end

  test "a member who is not the owner cannot allow it, from the model or the card" do
    invocation = propose("Keep replies short.")

    assert_raises(Invocation::NotTheApprover) { invocation.approve!(by: @member) }
    sign_in_via_ajent(subject: @member.oidc_sub, email: @member.email, name: "Milo")
    get workspace_path(@workspace)
    post conversation_invocation_approval_path(@conversation, invocation), params: { decision: "approve" }
    assert_redirected_to conversation_path(@conversation)
    assert_equal "Only Olive can allow this.", flash[:alert]
    assert invocation.reload.awaiting_person?
    assert_nil invocation.approval
    assert_equal "", @workspace.reload.instructions
  end

  test "allowed, it reaches every agent of the workspace on its next message, and no other workspace's, recording who" do
    before = [ @planner, @writer, @elsewhere ].map { it.conversation.definition[:digest] }
    invocation = propose(RULES)
    invocation.approve!(by: @owner)
    assert_equal "done", replay(invocation)[:status]

    assert_equal RULES, @workspace.reload.instructions
    [ @planner, @writer ].each do |agent|
      prompt = agent.reload.conversation.definition[:instructions]
      assert_includes prompt, "Your workspace's shared instructions"
      assert_includes prompt, RULES
      assert_not_includes agent.instructions, RULES, "its own instructions are its own"
    end
    assert_not_includes @elsewhere.reload.conversation.definition[:instructions], RULES
    after = [ @planner, @writer, @elsewhere ].map { it.reload.conversation.definition[:digest] }
    assert_not_equal before[0], after[0]
    assert_not_equal before[1], after[1]
    assert_equal before[2], after[2]

    revision = @workspace.revisions.sole
    assert_equal [ RULES, @owner, @planner, nil ], [ revision.instructions, revision.changed_by, revision.proposed_by_agent, revision.proposed_by ]
  end

  test "an agent's own self-edit is as before and leaves the workspace's alone" do
    @planner.update!(asks_every_instruction_change: false)
    with_setting(:app, :approve_everything, true) do
      assert receive("change_yourself", { "instructions" => "Plan the week.", "scope" => "yourself" })[:status] == "done"
    end
    assert_equal "Plan the week.", @planner.reload.instructions
    assert_equal "", @workspace.reload.instructions
    assert_empty @workspace.revisions
  end

  test "the owner edits them on the workspace page; a member reads them and cannot" do
    sign_in_via_ajent(subject: @owner.oidc_sub, email: @owner.email, name: "Olive")
    patch workspace_instructions_path(@workspace), params: { workspace: { instructions: RULES } }
    assert_redirected_to workspace_path(@workspace)
    assert_equal RULES, @workspace.reload.instructions
    assert_equal [ @owner ], @workspace.revisions.map(&:changed_by)
    get workspace_path(@workspace)
    assert_select "#workspace_instructions textarea[name='workspace[instructions]']", text: RULES

    sign_in_via_ajent(subject: @member.oidc_sub, email: @member.email, name: "Milo")
    patch workspace_instructions_path(@workspace), params: { workspace: { instructions: "Mine now." } }
    assert_response :not_found
    assert_equal RULES, @workspace.reload.instructions
    get workspace_path(@workspace)
    assert_select "#workspace_instructions textarea[name='workspace[instructions]']", 0
    assert_select "#workspace_instructions", /Never book travel without asking/
  end

  test "a member proposes a change; only the owner accepts or declines it" do
    @workspace.change_instructions(RULES, by: @owner)
    sign_in_via_ajent(subject: @member.oidc_sub, email: @member.email, name: "Milo")
    post workspace_proposals_path(@workspace), params: { proposal: { instructions: "Answer in British English.\nKeep replies short." } }
    assert_redirected_to workspace_path(@workspace)
    proposal = @workspace.proposals.sole
    assert_equal @member, proposal.proposed_by
    post workspace_proposal_acceptance_path(@workspace, proposal)
    assert_response :not_found
    assert_equal RULES, @workspace.reload.instructions

    sign_in_via_ajent(subject: @owner.oidc_sub, email: @owner.email, name: "Olive")
    get workspace_path(@workspace)
    assert_select "#workspace_proposal_#{proposal.id}", /Milo/
    assert_select "#workspace_proposal_#{proposal.id} .ui-fields dd", /Never book travel without asking/
    assert_select "#workspace_proposal_#{proposal.id} .ui-fields dd", /Keep replies short/
    post workspace_proposal_acceptance_path(@workspace, proposal)
    assert_redirected_to workspace_path(@workspace)
    assert_equal "Answer in British English.\nKeep replies short.", @workspace.reload.instructions
    assert_empty @workspace.proposals
    revision = @workspace.revisions.first
    assert_equal [ @owner, @member ], [ revision.changed_by, revision.proposed_by ]

    @workspace.proposals.create!(proposed_by: @member, instructions: "Declined.")
    delete workspace_proposal_path(@workspace, @workspace.proposals.sole)
    assert_redirected_to workspace_path(@workspace)
    assert_empty @workspace.reload.proposals, "the owner declined it"
    assert_equal "Answer in British English.\nKeep replies short.", @workspace.instructions
  end

  private
    def propose(instructions)
      outcome = receive("change_yourself", { "instructions" => instructions, "scope" => "workspace" })
      @conversation.invocations.find_by!(call_id: outcome[:call_id])
    end

    def replay(invocation) = receive(invocation.tool_name, invocation.arguments, call_id: invocation.call_id)

    def receive(tool, arguments, call_id: "propose_#{@next_call += 1}")
      @conversation.reload
      payload = invocation_payload(@conversation, tool: tool, arguments: arguments, call_id: call_id)
      Invocation.receive(@conversation, task_id: payload[:taskId], call_id: call_id, tool: tool,
        arguments: arguments, digest: payload[:digest]).deep_symbolize_keys.merge(call_id: call_id)
    end
end
