require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/email_test_helper"
require_relative "../test_helpers/voipms_test_helper"

class AgentsMailboxTest < ActionMailbox::TestCase
  include AgentTestHelper

  # Mail no person wrote just now: an auto-reply, a bounce, a list, a no-reply sender.
  AUTOMATED = [
    [ "maya@example.com", { "Auto-Submitted" => "auto-replied" } ],
    [ "maya@example.com", { "Precedence" => "bulk" } ],
    [ "maya@example.com", { "X-Autoreply" => "yes" } ],
    [ "news@example.com", { "List-Id" => "<news.example.com>" } ],
    [ "MAILER-DAEMON@mail.example.com", {} ],
    [ "no-reply@example.com", {} ],
    [ "donotreply@example.com", {} ]
  ].freeze
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
    old = @agent.user.personal_workspace.agents.create!(@agent.attributes.slice(*%w[ instructions model ]).merge(user: @agent.user, name: "Trips"))
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
    assert_equal "followUp", @submissions.sole["whenBusy"], "a person's email waits in the agent's inbox (#85)"
    assert_no_match "If this arrived while you were working", content
  end

  # An agent forwarded a reply to someone already copied, who then had it
  # twice: it was never shown Cc or Reply-To.
  test "who else it went to, where replies go, and a blind copy to the agent itself are shown with its other headers" do
    receive_inbound_email_from_mail(from: "Sam <sam@example.com>", to: "travel@agents.example", cc: "Ada <ada@example.com>, robin@example.com",
      reply_to: "Desk <desk@example.com>", subject: "Lunch", body: "Tuesday?", message_id: "cc1@example.com")

    assert_match "To: travel@agents.example\nCc: Ada <ada@example.com>, robin@example.com\nReply-To: Desk <desk@example.com>\n",
      @submissions.last["content"]
    assert_no_match "Bcc:", @submissions.last["content"], "named in To or Cc, it was not a blind copy"

    mail = Mail.new(from: "maya@example.com", to: "someone@example.com", subject: "Fwd", body: "Hotel booked", message_id: "<bcc1@example.com>")
    mail.header["Delivered-To"] = "travel@agents.example"
    receive_inbound_email_from_source(mail.to_s)
    assert_match "To: someone@example.com\nBcc: travel@agents.example\n", @submissions.last["content"]
  end

  test "mail with no Cc, Reply-To or blind copy shows only its subject, date and To, as before" do
    receive_inbound_email_from_mail(from: "sam@example.com", to: "travel@agents.example", subject: "Lunch", body: "Tuesday?",
      message_id: "plain1@example.com", date: Time.utc(2026, 11, 9, 10))

    assert_match(/Subject: Lunch\nDate: 2026-11-09T10:00:00\+00:00\nTo: travel@agents.example\n\nTuesday\?\z/, words(@submissions.last["content"]))
  end

  test "mail too long for one message arrives cut, saying so, rather than refused" do
    email = receive_inbound_email_from_mail(from: "news@example.com", to: "travel@agents.example",
      subject: "Digest", body: "\u{1F600}" * Conversation::WORDS_LIMIT, message_id: "long@example.com")

    assert email.delivered?
    content = words(@submissions.sole["content"])
    assert content.end_with?(Conversation::CUT)
    assert_operator Conversation.utf16_length(content), :<=, Conversation::WORDS_LIMIT
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

  test "with its own account as its only address, mail to its address here is turned away with one log line, and comes again once that is off" do
    account = @agent.create_mail_account!(address: "desk@mail.example.com", smtp_host: "smtp.mail.example.com", vault_entry: "Agent mailbox", primary: true)
    trips = replaced_by_travel.tap { it.update!(mail_to_agent: nil) }
    log = StringIO.new
    previous, Rails.logger = Rails.logger, ActiveSupport::Logger.new(log)
    email = begin
      receive_inbound_email_from_mail(from: "maya@example.com", to: "travel@agents.example, trips@agents.example", subject: "Secret plans",
        body: "Meet at noon.", message_id: "p1@example.com")
    ensure
      Rails.logger = previous
    end

    assert email.delivered?
    assert_equal [ "email:#{trips.id}:p1@example.com" ], @submissions.pluck("requestId"), "only the agent still using its address here takes it"
    lines = log.string.lines.grep(/not delivered/)
    assert_equal [ "Email to agent #{@agent.id}'s address here not delivered: it uses only its own mail account\n" ], lines
    assert_no_match(/Secret plans|Meet at noon|maya@example\.com/, log.string)
    assert ActionMailbox::InboundEmail.exists?(email.id), "nothing stored is deleted"

    account.update!(primary: false)
    receive_inbound_email_from_mail(from: "maya@example.com", to: "travel@agents.example", subject: "Again", body: "Hi", message_id: "p2@example.com")
    assert_equal "email:#{@agent.id}:p2@example.com", @submissions.last["requestId"]
  end

  test "a person's stop arriving while the agent is mid-turn reaches it at its next step; an automated notice waits for the turn to end" do
    receive_inbound_email_from_mail(from: "maya@example.com", to: "travel@agents.example", subject: "Lisbon", body: "Book it.", message_id: "m1@example.com")
    @agent.conversation.reload.receive_frame(seq: 1, busy: true, tail: "Looking at flights", failure: nil)
    assert_equal "running", @agent.conversation.reload.status, "mid-turn"

    receive_inbound_email_from_mail(from: "maya@example.com", to: "travel@agents.example", subject: "Re: Lisbon", body: "Stop: Porto, not Lisbon.",
      message_id: "m2@example.com")
    assert_equal "steer", @submissions.last["whenBusy"]
    assert_match "If this arrived while you were working", @submissions.last["content"]

    AUTOMATED.each_with_index do |(from, headers), index|
      mail = Mail.new(from: from, to: "travel@agents.example", subject: "Notice", body: "Automatic.", message_id: "<n#{index}@example.com>")
      headers.each { |name, value| mail.header[name] = value }
      receive_inbound_email_from_source(mail.to_s)
      assert_equal [ "email:#{@agent.id}:n#{index}@example.com", "followUp" ], @submissions.last.values_at("requestId", "whenBusy"), "#{from} #{headers}"
      assert_no_match "If this arrived while you were working", @submissions.last["content"]
    end
  end

  # The out-of-band inbox (#85): mail from people waits for the agent to
  # finish, or to take it in sooner, unless it can't wait. Plain rules: marked
  # urgent by its sender's mail program, opening with "urgent" or "stop", or
  # from the agent's own person.
  test "a person's mail waits in the inbox while the agent works, unless it is urgent, says stop, or comes from its own person" do
    receive_inbound_email_from_mail(from: "maya@example.com", to: "travel@agents.example", subject: "Lisbon", body: "Book it.", message_id: "w1@example.com")
    assert_equal "followUp", @submissions.last["whenBusy"], "it waits"
    assert_no_match "If this arrived while you were working", @submissions.last["content"]

    receive_inbound_email_from_mail(from: "maya@example.com", to: "travel@agents.example", subject: "STOP, wrong city", body: "Porto.", message_id: "w2@example.com")
    assert_equal "steer", @submissions.last["whenBusy"], "a stop goes in at the next step"

    receive_inbound_email_from_mail(from: "maya@example.com", to: "travel@agents.example", subject: "Lisbon", body: "Urgent: the fare ends today.", message_id: "w3@example.com")
    assert_equal "steer", @submissions.last["whenBusy"]

    marked = Mail.new(from: "maya@example.com", to: "travel@agents.example", subject: "Fare", body: "Today only.", message_id: "<w4@example.com>")
    marked.header["Importance"] = "High"
    receive_inbound_email_from_source(marked.to_s)
    assert_equal "steer", @submissions.last["whenBusy"], "marked urgent by the sender's mail program"

    receive_inbound_email_from_mail(from: "Alice <ALICE@example.com>", to: "travel@agents.example", subject: "Plans", body: "Use the window seat.", message_id: "w5@example.com")
    assert_equal "steer", @submissions.last["whenBusy"], "the owner's own mail always steers"
  end
end
