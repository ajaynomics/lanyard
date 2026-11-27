require "test_helper"
require_relative "../test_helpers/agent_test_helper"

class InvocationForgeWriteTest < ActiveSupport::TestCase
  include AgentTestHelper

  setup do
    @owner = create_user(name: "Robin")
    @conversation = create_conversation(@owner.agents.sole)
  end

  test "an existing uncertain write cannot reserve again until its owner resolves it" do
    original = make_write("first")
    first = Invocation::ForgeWrite.new(original)
    first.reserve!
    original.update!(state: :failed, error: Invocation::ForgeWrite::UNKNOWN)
    second = Invocation::ForgeWrite.new(make_write("second", wrapped: true))
    assert_raises(Tool::Refusal) { second.reserve! }
    assert_raises(Invocation::NotTheApprover) do
      original.resolve_forge_write!("not_applied", by: create_user(name: "Sam"))
    end
    assert_equal Invocation::ForgeWrite::UNRESOLVED, original.reload.result
    original.resolve_forge_write!("not_applied", by: @owner)
    assert_equal "not_applied", original.reload.result.fetch("forge_write")
    second.reserve!
    assert_raises(Tool::Refusal) { second.reserve! }
  end

  test "a receipt used on one existing write cannot settle a different write" do
    receipt = { "status" => "pushed", "receipt_id" => "11111111-1111-4111-8111-111111111111" }
    first = Invocation::ForgeWrite.new(make_write("first"))
    first.reserve!
    assert_equal receipt, first.confirm!(receipt)
    second = make_write("second")
    attempt = Invocation::ForgeWrite.new(second)
    attempt.reserve!
    assert_raises(Tool::Refusal) { attempt.confirm!(receipt) }
    assert_equal Invocation::ForgeWrite::UNRESOLVED, second.reload.result
  end

  private
    def make_write(call_id, wrapped: false)
      operation = { "verb" => "push", "repo" => "sample/project", "branch" => "review/topic", "expected_head" => "a" * 40,
        "revision" => (wrapped ? "c" : "b") * 40 }
      tool_name = wrapped ? "use_tool" : "forge"
      arguments = wrapped ? { "name" => "forge", "arguments" => operation } : operation
      @conversation.invocations.create!(task_id: "7", call_id:, tool_name:, arguments:, digest: "digest-#{call_id}",
        state: :running, started_at: Time.current)
    end
end
