require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/email_test_helper"

# An agent's sending hours (docs/email.md, "Sending hours"): mail that leaves
# the install's own people, allowed outside them, is not sent but held for
# the next opening, the agent and the thread told when; it goes then through
# the same mailer, so the forced Bcc too, unless the person cancels it first.
# The sidecar is stubbed at HTTP; the ledger, the jobs, the mailer and the
# sweep run for real, with the clock moved.
class SendingHoursTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include EmailTestHelper
  include ActiveJob::TestHelper

  ZONE = "America/Toronto".freeze

  setup do
    @access = Rails.application.config.x.access
    @previous_emails = @access[:emails]
    @access[:emails] = %w[ alice@example.com bob@example.com mallory@example.com ]
    ActionMailer::Base.deliveries.clear
    install_sidecar_settings
    install_email_settings
    @alice = create_user(name: "Alice")
    @agent = @alice.agents.sole
    @agent.update!(send_from: "08:00", send_until: "19:00", send_time_zone: ZONE)
    @conversation = create_conversation(@agent)
    sign_in_via_ajent(name: "Alice", subject: "sub-alice", email: "alice@example.com")
    @agent.create_mail_account!(address: "desk@mail.example.com", smtp_host: "smtp.mail.example.com", vault_entry: "Agent mailbox",
      forced_bcc: "records@example.org")
    @submissions = []
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").to_return { |request|
      @submissions << JSON.parse(request.body)
      { status: 202, body: { id: @submissions.size, status: "queued" }.to_json }
    }
  end
  teardown do
    @access[:emails] = @previous_emails
    travel_back
    remove_email_settings
    remove_sidecar_settings
  end

  test "outside its hours, allowed mail to someone outside is held for the next opening, said to the agent, and sent then with the Bcc" do
    travel_to Time.find_zone(ZONE).local(2026, 11, 16, 22, 22)
    done = allowed(mail_to("robin@outside.example"))

    assert_empty ActionMailer::Base.deliveries
    opening = Time.find_zone(ZONE).local(2026, 11, 17, 8, 0)
    assert_equal false, done["isError"]
    assert_equal [ "robin@outside.example" ], done.dig("result", "held")
    assert_equal opening.iso8601, done.dig("result", "sendsAt")
    assert_match "Outside your sending hours (08:00 to 19:00, America/Toronto)", done.dig("result", "why")
    held = @conversation.held_emails.sole
    assert held.held?

    @conversation.messages.create!(entry_key: "e1", entry_id: 1, role: "assistant", content: "Sending it.",
      tool_calls: [ { "id" => "c1", "name" => "send_email", "arguments" => mail_to("robin@outside.example") } ])
    get conversation_path(@conversation)
    assert_select ".held-email", text: /Held until Tue 17 Nov, 8:00 AM \(America\/Toronto\)/
    assert_select ".held-email form button", text: "Don't send"

    travel_to opening - 1.minute
    HeldEmailSweepJob.perform_now
    assert_empty ActionMailer::Base.deliveries, "not a minute early"

    travel_to opening + 30.seconds
    perform_enqueued_jobs(only: HeldEmailReportJob) { HeldEmailSweepJob.perform_now }
    mail = ActionMailer::Base.deliveries.sole
    assert_equal [ "robin@outside.example" ], mail.to
    assert_equal [ "records@example.org" ], mail.bcc
    assert held.reload.sent?
    told = @submissions.sole
    assert_equal "held_email:#{held.id}", told["requestId"]
    assert_match "The email to robin@outside.example, \"Trip\", held for your sending hours, was sent", told["content"]

    perform_enqueued_jobs(only: HeldEmailReportJob) { HeldEmailSweepJob.perform_now }
    assert_equal 1, ActionMailer::Base.deliveries.size, "sent once"
    get conversation_path(@conversation)
    assert_select ".held-email", text: /Sent Tue 17 Nov, 8:00 AM/
    assert_select ".held-email form", count: 0
  end

  test "within its hours, or to the install's own people at any hour, mail goes at once" do
    travel_to Time.find_zone(ZONE).local(2026, 11, 16, 10, 0)
    allowed(mail_to("robin@outside.example"), call_id: "c1")
    assert_equal [ [ "robin@outside.example" ] ], ActionMailer::Base.deliveries.map(&:to)

    travel_to Time.find_zone(ZONE).local(2026, 11, 16, 23, 0)
    allowed(mail_to("alice@example.com"), call_id: "c2")
    assert_equal [ "alice@example.com" ], ActionMailer::Base.deliveries.last.to
    assert_empty @conversation.held_emails
  end

  test "an outside address only in Cc or Bcc is held for the hours too, and goes with every recipient and the Bcc" do
    travel_to Time.find_zone(ZONE).local(2026, 11, 16, 23, 0)
    allowed(mail_to("alice@example.com").merge("cc" => [ "robin@outside.example" ]), call_id: "c1")
    allowed(mail_to("alice@example.com").merge("bcc" => [ "robin@outside.example" ]), call_id: "c2")
    assert_empty ActionMailer::Base.deliveries
    assert_equal 2, @conversation.held_emails.held.count

    travel_to Time.find_zone(ZONE).local(2026, 11, 17, 8, 1)
    perform_enqueued_jobs(only: HeldEmailReportJob) { HeldEmailSweepJob.perform_now }
    assert_equal %w[ sent sent ], @conversation.held_emails.order(:id).map { [ it.state, it.error ] }.map { it.compact.join(": ") }
    cc, bcc = ActionMailer::Base.deliveries.sort_by { it.cc.to_a.size }.reverse
    assert_equal [ "robin@outside.example" ], cc.cc
    assert_equal [ "records@example.org" ], cc.bcc
    assert_equal [ "robin@outside.example", "records@example.org" ], bcc.bcc
  end

  test "without hours set, mail goes at any hour, as before" do
    @agent.update!(send_from: nil, send_until: nil, send_time_zone: nil)
    travel_to Time.find_zone(ZONE).local(2026, 11, 16, 1, 57)
    allowed(mail_to("robin@outside.example"))
    assert_equal 1, ActionMailer::Base.deliveries.size
    assert_empty @conversation.held_emails
  end

  test "a held email the person cancels is never sent, the agent is told, and it can't be cancelled twice or after it went" do
    travel_to Time.find_zone(ZONE).local(2026, 11, 16, 22, 22)
    allowed(mail_to("robin@outside.example"))
    held = @conversation.held_emails.sole

    delete conversation_held_email_path(@conversation, held)
    assert_redirected_to conversation_path(@conversation)
    perform_enqueued_jobs(only: HeldEmailReportJob)
    assert held.reload.cancelled?
    assert_equal @alice, held.cancelled_by
    assert_match "Alice cancelled the email to robin@outside.example, \"Trip\", held for your sending hours. It was not sent.",
      @submissions.sole["content"]

    travel_to Time.find_zone(ZONE).local(2026, 11, 17, 9, 0)
    perform_enqueued_jobs(only: HeldEmailReportJob) { HeldEmailSweepJob.perform_now }
    assert_empty ActionMailer::Base.deliveries

    delete conversation_held_email_path(@conversation, held), headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_response :conflict
    assert_match "That email was already sent or cancelled.", response.body
  end

  test "another person's held email is not found" do
    travel_to Time.find_zone(ZONE).local(2026, 11, 16, 22, 22)
    allowed(mail_to("robin@outside.example"))
    held = @conversation.held_emails.sole

    create_user(name: "Mallory")
    sign_in_via_ajent(name: "Mallory", subject: "sub-mallory", email: "mallory@example.com")
    delete conversation_held_email_path(@conversation, held)
    assert_response :not_found
    assert held.reload.held?
  end

  test "hours changed meanwhile are kept: at its time a held email waits again if the hours are closed then" do
    travel_to Time.find_zone(ZONE).local(2026, 11, 16, 22, 22)
    allowed(mail_to("robin@outside.example"))
    @agent.update!(send_from: "10:00", send_until: "17:00")

    travel_to Time.find_zone(ZONE).local(2026, 11, 17, 8, 1)
    perform_enqueued_jobs(only: HeldEmailReportJob) { HeldEmailSweepJob.perform_now }
    assert_empty ActionMailer::Base.deliveries
    assert_equal Time.find_zone(ZONE).local(2026, 11, 17, 10, 0), @conversation.held_emails.sole.send_at
  end

  test "a held email the agent can no longer send fails, is said in the thread, and the agent is told" do
    travel_to Time.find_zone(ZONE).local(2026, 11, 16, 22, 22)
    allowed(mail_to("robin@outside.example"))
    remove_email_settings
    @agent.mail_account.destroy!

    travel_to Time.find_zone(ZONE).local(2026, 11, 17, 8, 1)
    perform_enqueued_jobs(only: HeldEmailReportJob) { HeldEmailSweepJob.perform_now }
    held = @conversation.held_emails.sole
    assert held.failed?
    assert_match "can't send email", held.error
    assert_match "was not sent", @submissions.sole["content"]
    install_email_settings
  end

  test "a queued held email report is discarded if its conversation was deleted" do
    travel_to Time.find_zone(ZONE).local(2026, 11, 16, 22, 22)
    allowed(mail_to("robin@outside.example"))
    job = HeldEmailReportJob.new(@conversation.held_emails.sole, "It ended.").serialize

    @conversation.destroy!
    assert_nothing_raised { ActiveJob::Base.execute(job) }
    assert_empty @submissions
  end

  test "the owner sets the hours on the agent's Channels; someone else in the workspace sees no such setting" do
    patch agent_sending_hours_path(@agent), params: { agent: { send_from: "8:00", send_until: "19:00", send_time_zone: ZONE } }
    assert_response :unprocessable_entity
    assert_select "[role=alert]", text: /must be a time such as 08:00/

    patch agent_sending_hours_path(@agent), params: { agent: { send_from: "07:30", send_until: "18:00", send_time_zone: "Mars/Olympus" } }
    assert_select "[role=alert]", text: /time zone/i

    patch agent_sending_hours_path(@agent), params: { agent: { send_from: "07:30", send_until: "18:00", send_time_zone: ZONE } }
    assert_redirected_to agent_channels_path(@agent)
    assert_equal [ "07:30", "18:00", ZONE ], @agent.reload.values_at(:send_from, :send_until, :send_time_zone)

    delete agent_sending_hours_path(@agent)
    assert_equal [ nil, nil, nil ], @agent.reload.values_at(:send_from, :send_until, :send_time_zone)

    bob = create_user(name: "Bob")
    @agent.workspace.memberships.create!(user: bob, role: "member")
    sign_in_via_ajent(name: "Bob", subject: "sub-bob", email: "bob@example.com")
    get agent_channels_path(@agent)
    assert_response :ok
    assert_select "#sending_hours", count: 0
    patch agent_sending_hours_path(@agent), params: { agent: { send_from: "00:00", send_until: "23:59", send_time_zone: ZONE } }
    assert_response :not_found
  end

  private
    def mail_to(address) = { "to" => [ address ], "subject" => "Trip", "body" => "Two nights." }

    def invoke(arguments, call_id:)
      post "/agent/invocations", params: invocation_payload(@conversation, tool: "send_email", arguments: arguments, call_id: call_id),
        headers: rails_bearer, as: :json
      response.parsed_body
    end

    # Allowed by the person where it asks, then run from its job, as the sidecar's replays see it.
    def allowed(arguments, call_id: "c1")
      invoke(arguments, call_id: call_id)
      invocation = @conversation.invocations.find_by!(call_id: call_id)
      invocation.approve!(by: @alice) if invocation.awaiting_person?
      invoke(arguments, call_id: call_id)
      perform_enqueued_jobs(only: InvocationCallJob)
      invoke(arguments, call_id: call_id)
    end
end
