require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/bluebubbles_test_helper"

# iMessage from the person's own phone (docs/imessage.md): the three tools,
# picked one by one, the person approving every send, and a send that never
# goes twice.
class Tool::ImessageTest < ActiveSupport::TestCase
  include AgentTestHelper
  include BluebubblesTestHelper
  include ActiveJob::TestHelper

  setup do
    install_bluebubbles_settings
    @maya = create_user(name: "Maya")
    @agent = @maya.agents.sole
    @conversation = create_conversation(@agent)
    @agent.update!(tool_names: @agent.tool_names | %w[ imessage_chats imessage_history imessage_send ])
  end

  teardown { remove_bluebubbles_settings }

  test "an agent has each only where the install has BlueBubbles and the person picked it" do
    assert_equal %w[ imessage_chats imessage_history imessage_send ], tool_names.grep(/imessage/)
    @agent.switch_tool("imessage_send", false)
    assert_equal %w[ imessage_chats imessage_history ], tool_names.grep(/imessage/)

    with_setting(:bluebubbles, :password, nil) do
      assert_empty tool_names.grep(/imessage/)
      assert_equal "failed", run_call("imessage_chats", "c1", {})[:status] == "done" && @conversation.invocations.find_by!(call_id: "c1").state
    end
  end

  test "it finds chats, and reads one as the person's and others' words, oldest first" do
    stub_bluebubbles(messages: [ bluebubbles_message("See you at 7", from_me: true, guid: "m2"), bluebubbles_message("Dinner?", guid: "m1") ])
    chats = run_call("imessage_chats", "c1", { "query" => "robin" })[:result]
    assert_equal [ FAMILY ], chats[:chats].pluck(:guid)

    history = run_call("imessage_history", "c2", { "chat" => MAYA })[:result]
    assert_equal [ [ "Maya Patel <+14165550199>", "Dinner?" ], [ "Maya", "See you at 7" ] ], history[:messages].map { it.values_at(:from, :text) }
    assert_equal true, history[:messages].last[:delivered]
  end

  test "each send waits for the person, even where the install allows everything, and offers no Always" do
    sends = stub_bluebubbles
    with_setting(:app, :approvals, "allow") do
      assert_equal "waiting", receive("imessage_send", { "chat" => MAYA, "bubbles" => [ "Running late", "10 min" ] }, call_id: "c1")[:status]
      assert_equal "done", run_call("imessage_chats", "c0", {})[:status], "reads don't ask"
    end
    invocation = @conversation.invocations.find_by!(call_id: "c1")
    assert_empty invocation.always_choices
    assert_equal "Send 2 iMessages to Maya Patel (Maya Patel <+14165550199>)?", Tool::ImessageSend.approval_title(invocation.arguments)
    assert_empty sends

    invocation.approve!(by: @maya)
    outcome = run_call("imessage_send", "c1", { "chat" => MAYA, "bubbles" => [ "Running late", "10 min" ] })
    assert_equal [ "Running late", "10 min" ], sends.pluck("message")
    assert_equal [ MAYA ], sends.pluck("chatGuid").uniq
    assert_equal({ chat: MAYA, bubbles: [ { text: "Running late", status: "delivered" }, { text: "10 min", status: "delivered" } ] }, outcome[:result])
  end

  test "where the install approves everything, a send goes at once, and its record still says what went" do
    sends = stub_bluebubbles
    outcome = with_setting(:app, :approve_everything, true) { run_call("imessage_send", "c1", { "chat" => MAYA, "bubbles" => [ "On my way" ] }) }
    assert_equal [ "On my way" ], sends.pluck("message")
    invocation = @conversation.invocations.find_by!(call_id: "c1")
    assert invocation.succeeded?
    assert_nil invocation.approval
    assert_equal [ "On my way" ], invocation.arguments["bubbles"]
    assert_equal "delivered", outcome[:result][:bubbles].sole[:status]
  end

  test "the card shows each bubble whole and apart, and names a group by its people" do
    stub_bluebubbles
    run_call("imessage_chats", "c0", {})
    receive("imessage_send", { "chat" => FAMILY, "bubbles" => [ "Dinner at 7, at ours", "Bring the dog" ] }, call_id: "c1")
    html = Nokogiri::HTML.fragment(ApplicationController.render(partial: "invocations/invocation", locals: { invocation: @conversation.invocations.find_by!(call_id: "c1") }))
    assert_equal "Send 2 iMessages to Family (Maya Patel <+14165550199>, Robin Lee <robin@example.com>)?", html.at_css(".approval h2, .approval .ui-card__title").text.strip
    assert_equal [ "Dinner at 7, at ours", "Bring the dog" ], html.css(".ui-fields__item").map(&:text)
    assert_equal [ "Allow once", "Deny" ], html.css(".ui-card__actions button").map { it.text.strip }
  end

  test "an uncertain send is reported as that, with what went before it, and is never sent again" do
    sends = stub_bluebubbles(send: ->(body) { body["message"] == "Second" ? { status: 500, body: "{}" } : nil })
    outcome = approved_send("c1", [ "First", "Second", "Third" ])
    assert_equal [ "First", "Second" ], sends.pluck("message")
    assert_equal "Bubble 2, \"Second\": BlueBubbles answered HTTP 500: it may or may not have gone. Before it: \"First\" (delivered). " \
      "Not sent after it: 1. Read the chat with imessage_history and tell the person; don't send again on your own.", outcome[:result][:error]

    travel(Invocation::RUN_LIMIT + 1.minute) { run_call("imessage_send", "c1", { "chat" => MAYA, "bubbles" => [ "First", "Second", "Third" ] }) }
    assert_equal 2, sends.size
  end

  test "a call made again after a crash sends only what hasn't gone, each bubble once" do
    sends = stub_bluebubbles(messages: [ bluebubbles_message("ok", from_me: true, at: Time.current.to_i * 1000) ])
    outcome = approved_send("c1", [ "ok", "ok", "See you" ])
    assert_equal [ "ok", "See you" ], sends.pluck("message")
    assert_equal [ "already sent", "delivered", "delivered" ], outcome[:result][:bubbles].pluck(:status)
  end

  test "a chat that isn't there is refused before anything goes" do
    sends = stub_bluebubbles
    outcome = approved_send("c1", [ "Hi" ], chat: "iMessage;-;+19055550100")
    assert_match(/There is no chat iMessage;-;\+19055550100/, outcome[:result][:error])
    assert_empty sends
  end

  private
    def tool_names = @agent.reload.conversation.definition[:tools].pluck(:name)

    def receive(tool, arguments, call_id:)
      payload = invocation_payload(@conversation, tool: tool, arguments: arguments, call_id: call_id)
      Invocation.receive(@conversation, task_id: payload[:taskId], call_id: call_id, tool: tool,
        arguments: arguments, digest: payload[:digest]).deep_symbolize_keys
    end

    def run_call(tool, call_id, arguments)
      receive(tool, arguments, call_id: call_id)
      perform_enqueued_jobs(only: InvocationCallJob)
      receive(tool, arguments, call_id: call_id)
    end

    def approved_send(call_id, bubbles, chat: MAYA)
      arguments = { "chat" => chat, "bubbles" => bubbles }
      receive("imessage_send", arguments, call_id: call_id)
      @conversation.invocations.find_by!(call_id: call_id).approve!(by: @maya)
      run_call("imessage_send", call_id, arguments)
    end
end
