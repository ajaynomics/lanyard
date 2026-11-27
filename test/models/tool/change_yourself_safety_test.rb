require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

class Tool::ChangeYourselfSafetyTest < ActiveSupport::TestCase
  include AgentTestHelper

  setup do
    @owner = create_user(name: "Fern")
    @workspace = Workspace.make(name: "Studio", owner: @owner)
    @agent = @owner.start_agent("Editor", workspace: @workspace)
    @conversation = create_conversation(@agent)
  end

  %w[ yourself workspace ].each do |scope|
    test "#{scope} requires Allow once under every permissive policy even with a stored Always" do
      @agent.update!(own_instruction_approval: scope == "yourself")
      target = store(scope, "Write short replies.")
      @agent.permissions.create!(tool_name: "change_yourself", granted_by: @owner)
      args = { "edits" => [ { "find" => "short", "replace" => "direct" } ] }
      [ [ :approvals, "allow" ], [ :approve_everything, true ] ].each do |setting, value|
        with_setting(:app, setting, value) { assert_approval_required(target, scope, args, setting.to_s) }
      end
      @workspace.update!(approval_policy: "everything")
      assert_approval_required(target, scope, args, "workspace-default")

      invocation = @conversation.invocations.find_by!(call_id: "workspace-default")
      invocation.approve!(by: @owner)
      assert_difference -> { target.revisions.count }, 1 do
        assert_equal "saved", invoke(scope, args, "workspace-default").dig(:result, :instructions)
      end
      assert_equal "Write direct replies.", target.reload.instructions
      assert_equal 1, @agent.permissions.count, "no new permission was saved"
    end

    test "#{scope} asks rather than refuses a rewrite of any size" do
      [ [ "a" * 14_268, "b" * 7_133 ], [ "a" * 1_000, "b" * 999 ] ].each_with_index do |(before, after), index|
        target = store(scope, before)
        assert_equal "waiting", invoke(scope, { "instructions" => after }, "any-size-#{index}")[:status]
        assert_equal before, target.reload.instructions
      end
    end

    test "#{scope} asks rather than refuses a placeholder-only rewrite" do
      target = store(scope, "a" * 1_000)
      assert_equal "waiting", invoke(scope, { "instructions" => "TODO" }, "placeholder")[:status]
      assert_equal "a" * 1_000, target.reload.instructions
    end

    test "#{scope} asks for the synthetic 14268 to 11 rewrite" do
      target = store(scope, "a" * 14_268)
      assert_equal "waiting", invoke(scope, { "instructions" => "b" * 11 }, "cut")[:status]
      assert_equal "a" * 14_268, target.reload.instructions
    end

    test "#{scope} allows a rewrite at both exact thresholds after approval" do
      target = store(scope, "🪁" * 2_000)
      after = "é" * 995 + " TODO"
      args = { "instructions" => after }
      assert_equal "waiting", invoke(scope, args, "boundary")[:status]
      @conversation.invocations.sole.approve!(by: @owner)
      assert_equal "saved", invoke(scope, args, "boundary").dig(:result, :instructions)
      assert_equal after, target.reload.instructions
    end
  end

  test "an unasked edit saves exactly once without approval or restore provenance" do
    @agent.update!(own_instruction_approval: false, instructions: "Write short replies.")
    @workspace.change_instructions("Ask before booking.", by: @owner)
    args = { "edits" => [ { "find" => "short", "replace" => "direct" } ] }

    assert_difference -> { @agent.revisions.count }, 1 do
      outcome = invoke("yourself", args, "unasked")
      assert_equal "saved", outcome.dig(:result, :instructions)
      assert_equal outcome, invoke("yourself", args, "unasked")
    end
    invocation = @conversation.invocations.sole
    assert_nil invocation.approval
    assert invocation.preview.key?("instruction_change")
    assert_equal "Write direct replies.", @agent.reload.instructions
    assert_nil @agent.revisions.first.approval_id
    assert_equal "Ask before booking.", @workspace.reload.instructions
  end

  test "with own-instruction approval off, a large cut saves and history keeps the version before it" do
    @agent.update!(own_instruction_approval: false, instructions: "a" * 2_000)
    assert_equal "saved", invoke("yourself", { "instructions" => "b" * 11 }, "cut").dig(:result, :instructions)
    assert_equal "b" * 11, @agent.reload.instructions
    assert_includes @agent.revisions.pluck(:instructions), "a" * 2_000
  end

  test "saving another approved edit keeps all earlier recorded revisions in both scopes" do
    %w[ yourself workspace ].each do |scope|
      target = store(scope, "Keep version 0.")
      original_ids = target.revisions.ids
      6.times do |index|
        args = { "edits" => [ { "find" => "version #{index}", "replace" => "version #{index + 1}" } ] }
        call_id = "#{scope}-#{index}"
        assert_equal "waiting", invoke(scope, args, call_id)[:status]
        @conversation.invocations.find_by!(call_id: call_id).approve!(by: @owner)
        assert_equal "saved", invoke(scope, args, call_id).dig(:result, :instructions)
      end
      assert_equal original_ids.sort, (target.revisions.ids & original_ids).sort
      assert_equal (1..6).map { "Keep version #{it}." }, target.revisions.reorder(id: :desc).limit(6).pluck(:instructions).reverse
    end
  end

  private
    def store(scope, text)
      if scope == "workspace"
        @workspace.change_instructions(text, by: @owner)
        @workspace
      else
        @agent.update!(instructions: text)
        @agent
      end
    end

    def assert_approval_required(target, scope, arguments, call_id)
      before = target.reload.instructions
      assert_no_difference -> { target.revisions.count } do
        assert_equal "waiting", invoke(scope, arguments, call_id)[:status]
        invocation = @conversation.invocations.find_by!(call_id: call_id)
        assert invocation.awaiting_person?
        assert_nil invocation.approval
        assert_empty invocation.always_choices
        assert_raises(ArgumentError) { invocation.approve!(by: @owner, always: "agent") }
      end
      assert_equal before, target.reload.instructions
    end

    def invoke(scope, args, call_id)
      arguments = args.merge("scope" => scope)
      payload = invocation_payload(@conversation.reload, tool: "change_yourself", arguments: arguments, call_id: call_id)
      Invocation.receive(@conversation, task_id: payload[:taskId], call_id: call_id, tool: "change_yourself",
        arguments: arguments, digest: payload[:digest]).deep_symbolize_keys
    end
end
