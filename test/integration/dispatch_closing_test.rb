require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# A text whose going is still unknown (Dispatch) is never decided by the
# app: its card says so in one line, and a person who checked the phone or
# voip.ms's log closes it there, as gone or not. The agent is told once.
# The sidecar is stubbed at HTTP; the ledger and jobs run.
class DispatchClosingTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include ActiveJob::TestHelper

  setup do
    @access = Rails.application.config.x.access
    @previous_emails = @access[:emails]
    @access[:emails] = %w[ maya@example.com mallory@example.com ]
    install_sidecar_settings
    @maya = create_user(name: "Maya")
    @agent = @maya.agents.sole
    @agent.update!(phone_number: "6475550123")
    @conversation = create_conversation(@agent)
    sign_in_via_ajent(name: "Maya", subject: "sub-maya", email: "maya@example.com")
    @told = []
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").to_return do |request|
      @told << JSON.parse(request.body)
      { status: 202, body: { id: @told.size, status: "queued" }.to_json }
    end
    @invocation = @conversation.invocations.create!(task_id: "7", call_id: "c1", tool_name: "send_text",
      arguments: { "to" => "4165550199", "body" => "On my way." }, digest: "d", state: "succeeded",
      result: { "unknown" => "4165550199", "from" => "6475550123" })
    @dispatch = Dispatch.record(@invocation, tool_name: "send_text", sender: "6475550123", fingerprint: "f")
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/12}).to_return(body: { status: "idle", entries: [], more: false }.to_json)
    @conversation.messages.create!(entry_key: "1", entry_id: 1, role: "assistant", content: "",
      tool_calls: [ { "id" => "c1", "name" => "send_text" } ])
  end

  teardown do
    @access[:emails] = @previous_emails
    remove_sidecar_settings
  end

  test "its card says in one line that it is still unknown, with It went and It didn't go" do
    @dispatch.update!(state: :unknown)
    get conversation_path(@conversation)

    assert_select ".dispatch .ui-card__title", "Text to 4165550199"
    assert_select ".dispatch [role=status]", "Still unknown whether this text went. Check the phone or voip.ms's message log, then say."
    assert_equal [ "It went", "It didn't go" ], css_select(".dispatch .ui-card__actions button").map { it.text.strip }
  end

  test "a person who checked closes it as gone: the agent is told once not to send it again, and it can't be closed twice" do
    @dispatch.update!(state: :unknown)

    patch conversation_invocation_dispatch_path(@conversation, @invocation), params: { state: "sent" }
    assert_redirected_to conversation_path(@conversation)
    perform_enqueued_jobs(only: DispatchReportJob)
    assert @dispatch.reload.sent?
    assert_equal @maya, @dispatch.closed_by
    assert_match(/Maya checked the text to 4165550199, "On my way\.", and says it went\. Don't send it again\./, @told.sole["content"])
    assert_equal "dispatch:#{@dispatch.id}:closed", @told.sole["requestId"]

    get conversation_path(@conversation)
    assert_select ".dispatch [role=status]", "Maya checked: it went."
    assert_select ".dispatch .ui-card__actions", count: 0

    patch conversation_invocation_dispatch_path(@conversation, @invocation), params: { state: "not_sent" },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_response :conflict
    assert @dispatch.reload.sent?
  end

  test "a person closes it as not gone: the agent may send it again" do
    @dispatch.update!(state: :unknown)

    patch conversation_invocation_dispatch_path(@conversation, @invocation), params: { state: "not_sent" }
    perform_enqueued_jobs(only: DispatchReportJob)
    assert @dispatch.reload.not_sent?
    assert_match(/Maya checked the text to 4165550199, "On my way\.", and says it didn't go\. Send it again if it is still wanted\./,
      @told.sole["content"])
  end

  test "a provider failure calls for a manual check without saying a background check is under way" do
    @invocation.update!(state: :failed, error: "voip.ms returned HTTP 522. The send failed. Check voip.ms's message log before any manual resend.")
    @dispatch.require_provider_check
    get conversation_path(@conversation)
    assert_select '.dispatch[data-state="check_before_resend"] [role=status]', @invocation.error

    patch conversation_invocation_dispatch_path(@conversation, @invocation), params: { state: "not_sent" }
    perform_enqueued_jobs(only: DispatchReportJob)
    assert @dispatch.reload.not_sent?
    assert_equal @maya, @dispatch.closed_by
    assert_match(/Don't resend unless your person asks for a new send/, @told.sole["content"])
  end

  test "one still being checked can't be closed yet, and nothing but gone or not gone closes it" do
    @dispatch.update!(state: :checking)
    patch conversation_invocation_dispatch_path(@conversation, @invocation), params: { state: "sent" }
    assert @dispatch.reload.checking?

    @dispatch.update!(state: :unknown)
    patch conversation_invocation_dispatch_path(@conversation, @invocation), params: { state: "pending" }
    assert_response :bad_request
    assert @dispatch.reload.unknown?
    assert_empty @told
  end

  test "a Concourse message still unknown is named as one, with where to look, and closed the same way" do
    invocation = @conversation.invocations.create!(task_id: "7", call_id: "c2", tool_name: "concourse_send",
      arguments: { "to" => "acme/travel", "text" => "Find me a flight" }, digest: "d", state: "succeeded", result: { "unknown" => "acme/travel" })
    dispatch = Dispatch.record(invocation, tool_name: "concourse_send", sender: "acme", fingerprint: "g")
    dispatch.update!(state: :unknown)
    @conversation.messages.create!(entry_key: "2", entry_id: 2, role: "assistant", content: "",
      tool_calls: [ { "id" => "c2", "name" => "concourse_send" } ])

    get conversation_path(@conversation)
    assert_select ".dispatch .ui-card__title", "Concourse message to acme/travel"
    assert_select ".dispatch [role=status]", "Still unknown whether this Concourse message went. Check Concourse's website, or with acme/travel's owner, then say."

    patch conversation_invocation_dispatch_path(@conversation, invocation), params: { state: "sent" }
    perform_enqueued_jobs(only: DispatchReportJob)
    assert dispatch.reload.sent?
    assert_match(/Maya checked the Concourse message to acme\/travel, "Find me a flight", and says it went\./, @told.sole["content"])
  end

  test "an iMessage still unknown is named by its chat, with where to look" do
    invocation = @conversation.invocations.create!(task_id: "7", call_id: "c3", tool_name: "imessage_send",
      arguments: { "chat" => "iMessage;-;+14165550199", "bubbles" => [ "Running late", "10 min" ] }, digest: "d", state: "succeeded", result: {})
    Dispatch.record(invocation, tool_name: "imessage_send", sender: "iMessage;-;+14165550199", fingerprint: "h").update!(state: :unknown)
    @conversation.messages.create!(entry_key: "3", entry_id: 3, role: "assistant", content: "",
      tool_calls: [ { "id" => "c3", "name" => "imessage_send" } ])

    get conversation_path(@conversation)
    assert_select ".dispatch .ui-card__title", "iMessage to +14165550199"
    assert_select ".dispatch [role=status]", "Still unknown whether this iMessage went. Check the chat in Messages on the phone, then say."
    assert_select ".dispatch .ui-fields__item", text: /iMessage;-;/, count: 0
  end

  test "an email still unknown says where to look, by its Message-ID, and closes the same way" do
    email = @conversation.invocations.create!(task_id: "7", call_id: "c2", tool_name: "send_email",
      arguments: { "to" => [ "alice@example.com" ], "subject" => "Your booking", "body" => "Two nights." }, digest: "d", state: "succeeded",
      result: { "unknown" => [ "alice@example.com" ], "messageId" => "k3y@mail.example.com" })
    dispatch = Dispatch.record(email, tool_name: "send_email", sender: "desk@mail.example.com", fingerprint: "g", provider_id: "k3y@mail.example.com")
    dispatch.unconfirmable
    @conversation.messages.create!(entry_key: "2", entry_id: 2, role: "assistant", content: "", tool_calls: [ { "id" => "c2", "name" => "send_email" } ])
    get conversation_path(@conversation)

    assert_select ".dispatch .ui-card__title", "Email to alice@example.com"
    assert_select ".dispatch [role=status]",
      "Still unknown whether this email went. Check the Sent folder for Message-ID <k3y@mail.example.com>, or ask the recipient, then say."

    patch conversation_invocation_dispatch_path(@conversation, email), params: { state: "not_sent" }
    perform_enqueued_jobs(only: DispatchReportJob)
    assert dispatch.reload.not_sent?
    assert_match(/Maya checked the email to alice@example\.com, "Your booking", and says it didn't go\. Send it again if it is still wanted\./,
      @told.sole["content"])
  end

  test "another person's is not found" do
    @dispatch.update!(state: :unknown)
    create_user(name: "Mallory")
    sign_in_via_ajent(name: "Mallory", subject: "sub-mallory", email: "mallory@example.com")

    patch conversation_invocation_dispatch_path(@conversation, @invocation), params: { state: "sent" }
    assert_response :not_found
    assert @dispatch.reload.unknown?
  end
end
