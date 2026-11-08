require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/email_test_helper"

# A request asks as pi asks: allow once, always for this agent, always with
# these recipients, or deny. "Always" is a Permission the person can see and
# remove, made only from their answer and from the call as recorded.
class PermissionTest < ActiveSupport::TestCase
  include AgentTestHelper
  include EmailTestHelper
  include ActiveJob::TestHelper

  setup do
    install_email_settings
    @maya = create_user(name: "Maya")
    @agent = @maya.agents.sole
    @conversation = create_conversation(@agent)
  end
  teardown { remove_email_settings }

  test "always for this agent: every later call of the tool runs unasked, until the person removes it" do
    @agent.notes.remember("old", "x")
    @agent.notes.remember("older", "y")
    asking = receive("forget_note", { "key" => "old" }, call_id: "c1")
    assert_equal %w[ agent ], asking.always_choices

    asking.approve!(by: @maya, always: "agent")

    permission = @agent.permissions.sole
    assert_equal [ "forget_note", "", @maya ], [ permission.tool_name, permission.recipient, permission.granted_by ]
    assert permission.every_call?
    assert receive("forget_note", { "key" => "older" }, call_id: "c2").succeeded?

    permission.destroy!
    assert receive("forget_note", { "key" => "other" }, call_id: "c3").awaiting_person?
  end

  test "always with a recipient covers that recipient, however it is written, and no one else" do
    asking = send_email("c1", "hotel@acme.example")
    assert_equal %w[ recipient agent ], asking.always_choices
    assert_equal [ "hotel@acme.example" ], asking.recipients

    asking.approve!(by: @maya, always: "recipient")

    assert_equal [ "hotel@acme.example" ], @agent.permissions.pluck(:recipient)
    assert send_email("c2", "Hotel@ACME.example").running?
    assert send_email("c3", "hotel@acme.example", "robin@elsewhere.example").awaiting_person?
    assert send_email("c4", "robin@elsewhere.example").awaiting_person?
    @agent.notes.remember("old", "x")
    assert receive("forget_note", { "key" => "old" }, call_id: "c5").awaiting_person?, "a recipient's Always is for its own tool"
  end

  test "allow once remembers nothing, and deny is a deny" do
    send_email("c1", "hotel@acme.example").approve!(by: @maya)
    assert send_email("c2", "hotel@acme.example").awaiting_person?
    @conversation.invocations.find_by!(call_id: "c2").deny!(by: @maya)
    assert_empty @agent.permissions
  end

  test "a change to the agent itself and a password fill are never Always" do
    asking = receive("change_yourself", { "name" => "Sam" }, call_id: "c1")
    assert asking.awaiting_person?
    assert_empty asking.always_choices
    assert_raises(ArgumentError) { asking.approve!(by: @maya, always: "agent") }
    assert asking.reload.awaiting_person?
    assert_empty @agent.permissions
    assert_not Tool::SignInWithSavedPassword.always?
  end

  test "a person's own tools that only read never ask" do
    assert_nil receive("list_notes", {}, call_id: "c1").asks
    assert receive("list_notes", {}, call_id: "c2").succeeded?
  end

  private
    def receive(tool, arguments, call_id:)
      payload = invocation_payload(@conversation, tool: tool, arguments: arguments, call_id: call_id)
      Invocation.receive(@conversation, task_id: payload[:taskId], call_id: call_id, tool: tool, arguments: arguments, digest: payload[:digest])
      @conversation.invocations.find_by!(call_id: call_id)
    end

    def send_email(call_id, *to) = receive("send_email", { "to" => to, "subject" => "Friday", "body" => "Two nights." }, call_id: call_id)
end
