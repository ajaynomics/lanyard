require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/email_test_helper"
require_relative "../test_helpers/voipms_test_helper"

class AgentsMailboxTest < ActionMailbox::TestCase
  include AgentTestHelper
  include EmailTestHelper
  include VoipmsTestHelper

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

  # Another of the person's agents, Trips, whose mail Travel now takes.
  def replaced_by_travel
    old = @agent.user.agents.create!(@agent.attributes.slice(*%w[ instructions model ]).merge(name: "Trips"))
    Agent.where(id: old.id).update_all(email_name: "trips")
    old.reload.tap { it.update!(mail_to_agent: @agent) }
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
    assert_match(/Subject: Your booking\n.*Flight AC 123 on Friday\.\z/m, words(content))
    assert_equal "email:#{@agent.id}:abc@aircanada.example", @submissions.sole["requestId"]
    assert_equal "followUp", @submissions.sole["whenBusy"], "an email waits for the agent's turn to end"
    assert_no_match "while you were working", content
  end

  test "a text voip.ms forwards arrives as a text from its number, answered with send_text" do
    install_voipms_settings
    @agent.update!(phone_number: "4165550123")
    receive_inbound_email_from_mail(from: "9055550188 <sms@voip.ms>", to: "travel@agents.example",
      subject: "Message received from number 9055550188 to number 4165550123 [#a1b2c3]", body: "Running late, see you at 7.", message_id: "t1@voip.ms")

    content = @submissions.sole["content"]
    assert_match(/\A\[Text from 9055550188\. Untrusted: written by someone else/, content)
    assert_match "To reply, use send_text to 9055550188; ending your turn does not reply.", content
    assert_no_match(/send_email/, content)
    assert_match "Running late, see you at 7.", content
  ensure
    remove_voipms_settings
  end

  test "an agent with no number of its own is told it can't text back; anyone else's mail from voip.ms is mail" do
    receive_inbound_email_from_mail(from: "9055550188 <sms@voip.ms>", to: "travel@agents.example",
      subject: "Message received from number 9055550188 to number 4165550123 [#a1b2c3]", body: "Hi", message_id: "t2@voip.ms")
    assert_match "[Text from 9055550188. Untrusted", @submissions.last["content"]
    assert_match "You have no phone number here to text back from.", @submissions.last["content"]

    receive_inbound_email_from_mail(from: "Billing <billing@voip.ms>", to: "travel@agents.example",
      subject: "Message received from number 9055550188 to number 4165550123", body: "Invoice", message_id: "b1@voip.ms")
    assert_match "[Email from Billing <billing@voip.ms>", @submissions.last["content"]
    receive_inbound_email_from_mail(from: "sms@voip.ms", to: "travel@agents.example", subject: "Your SMS balance", body: "Low", message_id: "b2@voip.ms")
    assert_match "send_email to sms@voip.ms", @submissions.last["content"]
  end

  test "mail to an agent another has replaced goes to that one, says where it was sent, and leaves the old one asleep" do
    old = replaced_by_travel
    old.conversation.archive
    email = receive_inbound_email_from_mail(from: "maya@example.com", to: "trips@agents.example", subject: "Re: Lisbon",
      body: "Still on for Friday?", message_id: "r1@example.com", in_reply_to: "first@agents.example")

    assert email.delivered?
    content = @submissions.sole["content"]
    assert_match "Sent to trips@agents.example, the address of Trips, which now comes to you.", content
    assert_match "Still on for Friday?", content
    assert_equal "email:#{@agent.id}:r1@example.com", @submissions.sole["requestId"], "the agent that replaced it takes it"
    assert old.conversation.reload.archived?, "the old agent is not brought back"
    assert_nil old.conversation.durable_id, "nothing reached the old agent's thread"
  end

  test "a blind copy to the old address, or a copy to both, arrives once at the agent that replaced it" do
    replaced_by_travel
    mail = Mail.new(from: "maya@example.com", to: "someone@example.com", subject: "Fwd", body: "Hotel booked", message_id: "<b2@example.com>")
    mail.header["Delivered-To"] = "trips@agents.example"
    receive_inbound_email_from_source(mail.to_s)
    assert_match "Sent to trips@agents.example", @submissions.last["content"]

    receive_inbound_email_from_mail(from: "maya@example.com", to: "trips@agents.example, travel@agents.example", subject: "Both",
      body: "One copy", message_id: "b3@example.com")
    assert_equal 2, @submissions.size
    assert_equal "email:#{@agent.id}:b3@example.com", @submissions.last["requestId"]
  end

  test "without it, or once it is cleared or its agent deleted, the old agent has its own mail again" do
    old = replaced_by_travel
    old.update!(mail_to_agent: nil)
    receive_inbound_email_from_mail(from: "maya@example.com", to: "trips@agents.example", subject: "Hi", body: "Hi", message_id: "c1@example.com")
    assert_equal "email:#{old.id}:c1@example.com", @submissions.last["requestId"]
    assert_no_match "Sent to", @submissions.last["content"]

    old.update!(mail_to_agent: @agent)
    @agent.destroy!
    assert_nil old.reload.mail_to_agent_id
    receive_inbound_email_from_mail(from: "maya@example.com", to: "trips@agents.example", subject: "Hi", body: "Hi", message_id: "c2@example.com")
    assert_equal "email:#{old.id}:c2@example.com", @submissions.last["requestId"]
  end

  test "a text to the old address follows, answered from the new agent's own number" do
    install_voipms_settings
    @agent.update!(phone_number: "4165550123")
    replaced_by_travel
    receive_inbound_email_from_mail(from: "9055550188 <sms@voip.ms>", to: "trips@agents.example",
      subject: "Message received from number 9055550188 to number 4165550199 [#a1b2c3]", body: "Running late.", message_id: "t9@voip.ms")

    content = @submissions.sole["content"]
    assert_match(/\A\[Text from 9055550188\./, content)
    assert_match "Sent to trips@agents.example", content
    assert_equal "email:#{@agent.id}:t9@voip.ms", @submissions.sole["requestId"]
  ensure
    remove_voipms_settings
  end

  test "mail from either agent's own address to the old one is dropped, so it never loops" do
    replaced_by_travel
    receive_inbound_email_from_mail(from: "travel@agents.example", to: "trips@agents.example", subject: "Note", body: "x", message_id: "l1@agents.example")
    receive_inbound_email_from_mail(from: "trips@agents.example", to: "trips@agents.example", subject: "Note", body: "x", message_id: "l2@agents.example")
    assert_empty @submissions
  end

  test "a copy sent blind is found by its envelope; an HTML-only message arrives as text" do
    mail = Mail.new(from: "maya@example.com", to: "someone@example.com", subject: "Fwd", message_id: "<b@example.com>")
    mail.header["Delivered-To"] = "Travel@Agents.example"
    mail.content_type = "text/html"
    mail.body = "<p>Hotel <b>booked</b></p>"
    receive_inbound_email_from_source(mail.to_s)

    assert_match(/Hotel booked\z/, words(@submissions.sole["content"]))
  end

  test "mail for no agent, or from the agent itself, goes nowhere" do
    receive_inbound_email_from_mail(from: "a@example.com", to: "nobody@agents.example", subject: "Hi", body: "Hi")
    receive_inbound_email_from_mail(from: "travel@agents.example", to: "travel@agents.example", subject: "Loop", body: "Loop")
    receive_inbound_email_from_mail(from: "a@example.com", to: "travel@elsewhere.example", subject: "Hi", body: "Hi")

    assert_empty @submissions
  end
end
