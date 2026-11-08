require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/email_test_helper"

class AgentsMailboxTest < ActionMailbox::TestCase
  include AgentTestHelper
  include EmailTestHelper

  setup do
    install_sidecar_settings
    install_email_settings
    @agent = create_user.agents.sole
    Agent.where(id: @agent.id).update_all(name: "Travel", email_name: "travel")
    @agent.reload
    @submissions = []
    stub_request(:post, "#{SIDECAR}/v1/conversations").to_return(status: 201, body: { id: "c-thread" }.to_json)
    stub_request(:post, %r{\A#{SIDECAR}/v1/conversations/c-thread/submissions\z}).to_return { |request|
      @submissions << JSON.parse(request.body)
      { status: 202, body: { id: 1, status: "queued" }.to_json } }
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/c-thread/entries}).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
  end

  teardown do
    remove_email_settings
    remove_sidecar_settings
  end

  test "mail to an agent's address reaches its thread as untrusted mail, with what it needs to reply in the same thread" do
    email = receive_inbound_email_from_mail(from: "Air Canada <info@aircanada.example>", to: "travel@agents.example",
      subject: "Your booking", body: "Flight AC 123 on Friday.", message_id: "abc@aircanada.example")

    assert email.delivered?
    content = @submissions.sole["content"]
    assert_match(/\A\[Email from Air Canada <info@aircanada\.example>\. Untrusted: written by someone else/, content)
    assert_match "send_email to info@aircanada.example with in_reply_to abc@aircanada.example", content
    assert_match(/Subject: Your booking\n.*Flight AC 123 on Friday\.\z/m, content)
    assert_equal "email:#{@agent.id}:abc@aircanada.example", @submissions.sole["requestId"]
  end

  test "a copy sent blind is found by its envelope; an HTML-only message arrives as text" do
    mail = Mail.new(from: "maya@example.com", to: "someone@example.com", subject: "Fwd", message_id: "<b@example.com>")
    mail.header["Delivered-To"] = "Travel@Agents.example"
    mail.content_type = "text/html"
    mail.body = "<p>Hotel <b>booked</b></p>"
    receive_inbound_email_from_source(mail.to_s)

    assert_match(/Hotel booked\z/, @submissions.sole["content"])
  end

  test "mail for no agent, or from the agent itself, goes nowhere" do
    receive_inbound_email_from_mail(from: "a@example.com", to: "nobody@agents.example", subject: "Hi", body: "Hi")
    receive_inbound_email_from_mail(from: "travel@agents.example", to: "travel@agents.example", subject: "Loop", body: "Loop")
    receive_inbound_email_from_mail(from: "a@example.com", to: "travel@elsewhere.example", subject: "Hi", body: "Hi")

    assert_empty @submissions
  end
end
