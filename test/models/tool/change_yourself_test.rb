require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

class Tool::ChangeYourselfTest < ActiveSupport::TestCase
  include AgentTestHelper
  include ActiveJob::TestHelper

  setup do
    @alice = create_user(name: "Alice")
    @agent = @alice.agents.sole
    @conversation = create_conversation(@agent)
  end

  test "every agent has it, and it asks the person first" do
    assert_includes @agent.conversation.definition[:lookup].pluck(:name), "change_yourself", "looked up: not in Tool::Catalog::CORE"
    assert_equal :approval, @agent.conversation.tool("change_yourself").asks

    assert_equal "waiting", receive("change_yourself", { "instructions" => "Grow tomatoes." }, call_id: "c1")[:status]
    assert_not_equal "Grow tomatoes.", @agent.reload.instructions
  end

  test "once allowed it replaces the agent's instructions, keeping a revision; its name is not its to change" do
    assert_difference -> { @agent.revisions.count } do
      assert_equal({ instructions: "saved" }, approved("c1", "instructions" => "Grow tomatoes.")[:result])
    end
    assert_equal [ "Assistant", "Grow tomatoes." ], @agent.reload.values_at(:name, :instructions)
    assert_equal %w[ instructions edits scope note_to_approver ], Tool::ChangeYourself.schema["properties"].keys
  end

  # It is looked up, so the model calls it by name once tool_search finds it.
  test "looked up, the workspace scope still decides who may allow it" do
    assert_not @conversation.declares?("change_yourself")
    assert_equal "waiting", receive("change_yourself", { "instructions" => "Share the shed.", "scope" => "workspace" }, call_id: "c1")[:status]
    invocation = @conversation.invocations.sole

    assert_equal @agent.workspace.owner, invocation.approver
    assert_equal "Change #{@agent.workspace}'s shared instructions?", invocation.approval_title
    assert_match "Only #{@agent.workspace.owner}, its owner, can allow it.", invocation.approval_note
  end

  test "allowing a personal replacement after a newer edit cannot overwrite it" do
    args = { "instructions" => "Replace this." }
    assert_equal "waiting", receive("change_yourself", args, call_id: "c1")[:status]
    @agent.update!(instructions: "Newer edit.")

    assert_no_difference -> { @agent.revisions.count } do
      invocation = @conversation.invocations.sole
      assert_raises(Invocation::StaleApproval) { invocation.approve!(by: @alice) }
      assert_nil invocation.reload.approval
      assert receive("change_yourself", args, call_id: "c1")[:isError]
    end
    assert_equal "Newer edit.", @agent.reload.instructions
  end

  test "personal text that changes and changes back still invalidates an allowed change" do
    @agent.update!(instructions: "Use short replies.")
    args = { "instructions" => "Use direct replies." }
    assert_equal "waiting", receive("change_yourself", args, call_id: "c1")[:status]
    invocation = @conversation.invocations.sole
    invocation.approve!(by: @alice)
    @agent.update!(instructions: "Use long replies.")
    @agent.update!(instructions: "Use short replies.")

    assert_no_difference -> { @agent.revisions.count } do
      outcome = receive("change_yourself", args, call_id: "c1")
      assert_match "read the current instructions and propose a new change", outcome.dig(:result, :error)
    end
    assert_equal "Use short replies.", @agent.reload.instructions
    assert invocation.reload.failed?
  end

  test "an allowed change records its approval, its call and the digest of the text allowed" do
    approved("c1", "instructions" => "Grow tomatoes.")
    invocation = @conversation.invocations.sole
    revision = @agent.revisions.last
    assert_equal [ invocation.approval, invocation, @agent.workspace ], [ revision.approval, revision.invocation, revision.instruction_workspace ]
    assert_equal Digest::SHA256.hexdigest("Grow tomatoes."), revision.approved_digest
  end

  test "expired, withdrawn, unbound and outside cards never produce instruction revisions" do
    args = { "instructions" => "Keep it direct." }
    %w[ expired withdrawn unbound approved outside ].each { |id| assert_equal "waiting", receive("change_yourself", args, call_id: id)[:status] }
    expired, withdrawn, unbound, approved, outside = @conversation.invocations.order(:id)
    expired.update!(expires_at: 1.second.ago)
    withdrawn.withdraw!
    [ approved, outside ].each { it.approve!(by: @alice) }
    [ unbound, approved ].each { it.update!(preview: nil) }
    outside.update!(state: :running)

    assert_no_difference -> { @agent.revisions.count } do
      assert_raises(Invocation::Conflict) { expired.approve!(by: @alice) }
      assert_raises(Invocation::Conflict) { withdrawn.approve!(by: @alice) }
      assert_raises(Invocation::StaleApproval) { unbound.approve!(by: @alice) }
      %w[ expired withdrawn approved ].each { assert receive("change_yourself", args, call_id: it)[:isError] }
      outside.call_outside
      assert receive("change_yourself", args, call_id: "outside")[:isError]
    end
    assert_not_equal "Keep it direct.", @agent.reload.instructions
  end

  test "a known failure saving a result rolls back the instruction and revision before recording failure" do
    @agent.update!(instructions: "Keep it brief.")
    args = { "instructions" => "Keep it direct." }
    assert_equal "waiting", receive("change_yourself", args, call_id: "c1")[:status]
    @conversation.invocations.sole.approve!(by: @alice)
    failure = ->(invocation) do
      if invocation.instruction_change? && invocation.succeeded?
        raise ActiveRecord::RecordInvalid.new(invocation)
      end
    end
    Invocation.set_callback(:update, :after, failure)

    assert_no_difference -> { @agent.revisions.count } do
      result = receive("change_yourself", args, call_id: "c1")
      assert result[:isError]
      assert_equal result, receive("change_yourself", args, call_id: "c1")
    end
    assert_equal "Keep it brief.", @agent.reload.instructions
    invocation = @conversation.invocations.sole
    assert invocation.failed?
    assert_nil invocation.result
  ensure
    Invocation.skip_callback(:update, :after, failure) if failure
  end

  test "an edit batch validates every match on the same base before asking or saving" do
    @agent.update!(instructions: "Write plainly.\nKeep replies short.")
    invalid = { "edits" => [ { "find" => "plainly", "replace" => "clearly" }, { "find" => "missing", "replace" => "here" } ] }
    valid = { "edits" => [ { "find" => "plainly", "replace" => "clearly" }, { "find" => "short", "replace" => "brief" } ] }

    assert_no_difference -> { @agent.revisions.count } do
      outcome = receive("change_yourself", invalid, call_id: "c1")
      assert outcome[:isError]
      assert_match "Edit 2 does not match", outcome.dig(:result, :error)
      assert_equal "Write plainly.\nKeep replies short.", @agent.reload.instructions
      assert_equal "waiting", receive("change_yourself", valid, call_id: "c2")[:status]
    end

    assert_difference -> { @agent.revisions.count } do
      assert_equal({ instructions: "saved" }, approved("c2", valid)[:result])
    end
    assert_equal "Write clearly.\nKeep replies brief.", @agent.reload.instructions
  end

  test "only a bounded nonempty batch or one rewrite is accepted" do
    limit = Tool::ChangeYourself::LIMIT
    valid_edit = edit("old", "new")
    malformed = [ {}, { "instructions" => "Write plainly.", "edits" => [ valid_edit ] }, { "edits" => nil },
      { "edits" => [] }, { "edits" => valid_edit }, { "edits" => [ edit("", "new") ] },
      { "edits" => [ { "find" => "old" } ] }, { "edits" => [ edit("old", nil) ] },
      { "edits" => [ valid_edit.merge("offset" => 0) ] }, { "edits" => [ valid_edit ] * 33 },
      { "edits" => [ edit("x" * (limit + 1), "new") ] }, { "instructions" => "x" * (limit + 1) },
      { "edits" => [ edit("x" * limit, "y" * limit), edit("z", "w") ] } ]
    @agent.update!(instructions: "This is old.")

    assert_no_difference -> { @agent.revisions.count } do
      malformed.each_with_index do |arguments, index|
        assert receive("change_yourself", arguments, call_id: "bad#{index}")[:isError], "accepted malformed case #{index}"
      end
    end
    assert_equal "This is old.", @agent.reload.instructions
    assert_equal malformed.size, @conversation.invocations.failed.count
  end

  test "literal comparisons reject repeated or overlapping matches, overlapping ranges and no-ops" do
    @agent.update!(instructions: "aaaa / two two / abcde / xxy / [z].")
    invalid_edits = {
      "more than once" => [ [ edit("aaa", "b") ], [ edit("two", "one") ] ],
      "edits overlap" => [ [ edit("abc", "1"), edit("cde", "2") ] ],
      "does not match" => [ [ edit("a.*e", "f") ], [ edit("abcde", "first"), edit("first", "second") ] ],
      "makes no change" => [ [ edit("[z]", "[z]") ], [ edit("xxy", ""), edit(" / [z]", "xxy / [z]") ] ]
    }
    count = 0
    assert_no_difference -> { @agent.revisions.count } do
      invalid_edits.each do |error, variants|
        variants.each do |edits|
          result = receive("change_yourself", { "edits" => edits }, call_id: "bad#{count += 1}")
          assert result[:isError]
          assert_match(/#{Regexp.escape(error)}/i, result.dig(:result, :error))
        end
      end
    end
    assert_equal "aaaa / two two / abcde / xxy / [z].", @agent.reload.instructions
    assert_equal count, @conversation.invocations.failed.count
  end

  test "a tool batch preserves Unicode and CRLF and returns the recorded result without a job or another revision" do
    @agent.update!(instructions: "🪁 [a.*]\\1\r\nKeep café.\r\nRemove this.")
    args = { "edits" => [ edit("\r\nRemove this.", ""), edit("[a.*]\\1", "[β]\\2"), edit("café", "茶") ] }
    assert_equal "waiting", receive("change_yourself", args, call_id: "script/c1")[:status]
    invocation = @conversation.invocations.sole
    snapshot = invocation.preview.fetch("instruction_change")
    assert_equal @agent.revisions.maximum(:id), snapshot.dig("base", "revision_id")
    assert_equal Digest::SHA256.hexdigest(@agent.instructions), snapshot.dig("base", "text_digest")
    assert_equal invocation.digest, snapshot.fetch("call_digest")
    assert_not_includes snapshot.to_json, "Keep café."
    assert_equal snapshot, invocation.reload.preview.fetch("instruction_change")

    invocation.approve!(by: @alice)
    assert_no_enqueued_jobs(only: InvocationCallJob) do
      assert_difference -> { @agent.revisions.count }, 1 do
        outcome = receive("change_yourself", args, call_id: "script/c1")
        assert_equal({ instructions: "saved" }, outcome[:result])
        assert_equal outcome, receive("change_yourself", args, call_id: "script/c1")
      end
    end
    assert_equal "🪁 [β]\\2\r\nKeep 茶.", @agent.reload.instructions
    assert_equal @agent.instructions, @agent.revisions.order(id: :desc).pick(:instructions)
    assert invocation.reload.succeeded?
    assert_raises(Invocation::Conflict) { receive("change_yourself", { "instructions" => "Another request." }, call_id: "script/c1") }
  end

  test "legacy rewrites keep identity cleanup, but an edit must already equal the exact normalized result" do
    @agent.update!(instructions: "Keep notes.")
    identity = "Your name is Assistant. Neither can be changed.\n\n"
    args = { "edits" => [ edit("Keep", "#{identity}Take") ] }
    assert_no_difference -> { @agent.revisions.count } do
      outcome = receive("change_yourself", args, call_id: "c1")
      assert outcome[:isError]
      assert_match "outside the exact edits", outcome.dig(:result, :error)
    end

    text = "Take notes."
    assert_equal "waiting", receive("change_yourself", { "instructions" => identity + text }, call_id: "c2")[:status]
    card = @conversation.invocations.find_by!(call_id: "c2")
    assert_not_includes card.details.to_json, "Neither can be changed"
    assert_equal({ instructions: "saved" }, approved("c2", "instructions" => identity + text)[:result])
    assert_equal text, @agent.reload.instructions
  end

  test "the soft warning is measured in characters and does not replace the hard result cap" do
    @agent.update!(instructions: "🪁" * 11_999 + "x")
    limit = Tool::ChangeYourself::LIMIT
    full = { "edits" => [ edit("x", "y") ] }
    assert_equal "waiting", receive("change_yourself", full, call_id: "at")[:status]
    assert_not @conversation.invocations.find_by!(call_id: "at").details.key?("warning")

    oversized = { "edits" => [ edit("x", "n" * limit) ] }
    assert_no_difference -> { @agent.revisions.count } do
      result = receive("change_yourself", oversized, call_id: "over-cap")
      assert result[:isError]
      assert_match "exceed #{limit} characters", result.dig(:result, :error)
    end

    over_warning = { "edits" => [ edit("x", "yz") ] }
    assert_equal "waiting", receive("change_yourself", over_warning, call_id: "over-warning")[:status]
    card = @conversation.invocations.find_by!(call_id: "over-warning")
    assert_match "deleting one line for each line you add", card.details.fetch("warning")
    assert_match "exceed 12,000 characters", approved("over-warning", over_warning).dig(:result, :warning)
    assert_equal 12_001, @agent.reload.instructions.length
  end


  private
    def receive(tool, arguments, call_id:)
      @conversation.reload
      payload = invocation_payload(@conversation, tool: tool, arguments: arguments, call_id: call_id)
      Invocation.receive(@conversation, task_id: payload[:taskId], call_id: call_id, tool: tool,
        arguments: arguments, digest: payload[:digest]).deep_symbolize_keys
    end

    def edit(find, replace) = { "find" => find, "replace" => replace }

    # The call as the sidecar replays it after the person allows it.
    def approved(call_id, arguments)
      receive("change_yourself", arguments, call_id: call_id)
      @conversation.invocations.find_by!(call_id: call_id).approve!(by: @alice)
      receive("change_yourself", arguments, call_id: call_id)
    end
end
