require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/bluebubbles_test_helper"

# iMessage from the person's own phone (docs/imessage.md): the four tools,
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
    @agent.update!(tool_names: @agent.tool_names | %w[ imessage_chats imessage_history imessage_attachment imessage_send ])
  end

  teardown { remove_bluebubbles_settings }

  test "an agent has each only where the install has BlueBubbles and the person picked it" do
    assert_equal %w[ imessage_chats imessage_history imessage_attachment imessage_send ], tool_names.grep(/imessage/)
    @agent.switch_tool("imessage_send", false)
    assert_equal %w[ imessage_chats imessage_history imessage_attachment ], tool_names.grep(/imessage/)

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

  test "a photo is listed by its GUID, and saving it names the file in the ledger and fetches its bytes only when the sidecar asks" do
    stub_bluebubbles(messages: [ bluebubbles_message("Look", guid: "m1").merge(attachments: [ { guid: PHOTO, transferName: "IMG_0001.HEIC", mimeType: "image/heic" } ]) ])
    bytes = stub_bluebubbles_attachment("heic-bytes".b)
    history = run_call("imessage_history", "c1", { "chat" => MAYA })[:result]
    assert_equal [ { guid: PHOTO, name: "IMG_0001.HEIC", type: "image/heic" } ], history[:messages].sole[:attachments]

    outcome = run_call("imessage_attachment", "c2", { "attachment" => PHOTO })
    assert_equal true, outcome[:file]
    assert_equal({ attachment: PHOTO, file: { name: "IMG_0001.jpg", type: "image/jpeg", size: 10 } }, outcome[:result])
    assert_not_requested bytes
    invocation = @conversation.invocations.find_by!(call_id: "c2")
    assert_equal "heic-bytes", invocation.download_file.read
    travel(Invocation::FILE_WITHIN + 1.minute) { assert_nil invocation.reload.download_file }
    assert_equal "done", run_call("imessage_history", "c1", { "chat" => MAYA })[:status]
    assert_nil @conversation.invocations.find_by!(call_id: "c1").download_file, "only a tool that saves a file can be fetched"
  end

  test "an attachment over 25 MB is saved like any other, and one not a GUID is refused" do
    stub_bluebubbles_attachment("", size: 30.megabytes)
    outcome = run_call("imessage_attachment", "c1", { "attachment" => PHOTO })
    assert_equal true, outcome[:file]
    assert_equal 30.megabytes, outcome[:result][:file][:size]

    assert_not_empty Tool::ImessageAttachment.errors_for("attachment" => "/Users/someone/Library/Messages/Attachments/a.heic")
    assert_not_empty Tool::ImessageAttachment.errors_for("attachment" => "#{PHOTO}/../../server")
    assert_empty Tool::ImessageAttachment.errors_for("attachment" => "at_0_#{PHOTO}")
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

  # The case of #86, on iMessage: BlueBubbles took a text and gave no answer
  # in time; the call failed as "may or may not have gone", and a retry the
  # person allowed again would send the same words twice.
  test "BlueBubbles takes a send and hangs past the wait: the call says sent, and the agent's retry sends nothing" do
    taken = bluebubbles_taking_then_hanging
    outcome = approved_send("c1", [ "On my way" ])
    assert_equal({ chat: MAYA, bubbles: [ { text: "On my way", status: "delivered" } ] }, outcome[:result], "sent, not failed")
    assert_equal [ "sent", "taken-1" ], @conversation.invocations.find_by!(call_id: "c1").dispatch.values_at(:state, :provider_id)

    retry_outcome = approved_send("c2", [ "On my way" ])
    assert retry_outcome[:isError]
    assert_match(/These same iMessages went to #{Regexp.escape(MAYA)} at .*, so they weren't sent again/, retry_outcome[:result][:error])
    assert_equal 1, taken.size, "sent once"

    travel(Dispatch::REPEAT_WITHIN + 1.minute) { approved_send("c3", [ "On my way" ]) }
    assert_equal 2, taken.size, "the same words later are a new message"
  end

  test "one the chat doesn't show yet is unknown with its key, a retry meanwhile sends nothing, and once shown the agent is told it went" do
    install_sidecar_settings
    told = []
    stub_request(:post, %r{/v1/conversations/12/submissions}).to_return do |request|
      told << JSON.parse(request.body)
      { status: 202, body: { id: told.size, status: "queued" }.to_json }
    end
    taken = bluebubbles_taking_then_hanging(listed_after: 3.minutes)

    outcome = approved_send("c1", [ "First", "Second" ])
    dispatch = @conversation.invocations.find_by!(call_id: "c1").dispatch
    assert_equal({ chat: MAYA, bubbles: [ { text: "First", status: "unknown" }, { text: "Second", status: "not sent" } ], key: dispatch.key,
                   note: Tool::ImessageSend::UNCONFIRMED }, outcome[:result])
    assert dispatch.checking?

    retry_outcome = approved_send("c2", [ "First", "Second" ])
    assert_match(/may have gone and are still being checked \(key #{dispatch.key}\), so they weren't sent again/, retry_outcome[:result][:error])

    travel(Dispatch::CHECK_AFTER + 1.second) { perform_enqueued_jobs(only: DispatchCheckJob, at: Time.current) }
    assert dispatch.reload.checking?, "not shown yet: checked again later"
    travel(10.minutes) do
      perform_enqueued_jobs(only: DispatchCheckJob, at: Time.current)
      perform_enqueued_jobs(only: DispatchReportJob)
    end
    assert_equal [ "sent", "taken-1" ], [ dispatch.reload.state, dispatch.provider_id ]
    assert_match(/imessage_send .*First.*went after all: its id is taken-1\. Don't send it again/, told.sole["content"])
    assert_equal [ "First" ], taken.pluck(:text), "sent once, and nothing after the one in doubt"
  ensure
    remove_sidecar_settings
  end

  test "a bubble in doubt after one that went is sent only once the chat shows it, and is never settled as not sent" do
    stub_bluebubbles(messages: -> { [ bluebubbles_message("First", from_me: true, guid: "m1", at: Time.current.to_i * 1000) ] },
      send: ->(body) { body["message"] == "Second" ? { status: 500, body: "{}" } : { guid: "m1", isFromMe: true, error: 0, isDelivered: true } })
    outcome = approved_send("c1", [ "First", "Second", "Third" ])
    assert_equal [ "delivered", "unknown", "not sent" ], outcome[:result][:bubbles].pluck(:status)
    dispatch = @conversation.invocations.find_by!(call_id: "c1").dispatch

    travel(Dispatch::CHECK_AFTER + 1.second) { dispatch.check }
    assert dispatch.reload.checking?, "the first is in the chat, the second not: not sent yet"
    travel(Dispatch::NOT_LISTED_AFTER + 1.minute) { dispatch.check }
    assert dispatch.reload.unknown?, "still not shown an hour on: unknown, for a person to say"
  end

  test "a send Messages refused is reported as not sent, with why" do
    stub_bluebubbles(send: send_error("1:2: execution error: Messages got an error: Can't make any into type constant. (-1700)"))
    outcome = approved_send("c1", [ "First", "Second" ])
    assert_equal "Bubble 1, \"First\": Messages can't send to that chat's address: it was not sent. Not sent after it: 1. " \
      "Read the chat with imessage_history and tell the person; don't send again on your own.", outcome[:result][:error]
  end

  test "a call whose send was recorded never sends again, even if its job runs twice" do
    taken = bluebubbles_taking_then_hanging(listed_after: 1.day)
    first = approved_send("c1", [ "Hi" ])
    assert first[:result][:key]
    invocation = @conversation.invocations.find_by!(call_id: "c1")

    invocation.update_columns(state: "running", result: nil)
    travel(1.day + 1.minute) { invocation.call_outside }
    assert_equal 1, taken.size, "not sent again"
    assert_match(/Sent once already, so not sent again/, invocation.reload.result["note"], "found in the chat")
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
