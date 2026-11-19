require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/email_test_helper"
require_relative "../../test_helpers/push_test_helper"

# What a person hears about while away: an agent that needs them (a card
# starts waiting) and an agent that finished a reply. Nothing else, nothing
# without the install's keys or a device, and never a tool's arguments.
class Conversation::NotifiableTest < ActiveSupport::TestCase
  include AgentTestHelper
  include EmailTestHelper
  include PushTestHelper
  include ActiveJob::TestHelper

  setup do
    install_email_settings
    install_push_settings
    @robin = create_user(name: "Robin")
    @agent = @robin.agents.sole
    name_agent(@agent, "Iris")
    @conversation = create_conversation(@agent)
    subscribe(@robin)
  end
  teardown do
    remove_email_settings
    remove_push_settings
  end

  test "a card waiting on the person says the agent needs them, with the card's title and not the call's arguments" do
    send_email("c1")

    notice = sole_notice
    card = @conversation.invocations.sole
    assert_equal({ kind: "needs_you", level: "priority", title: "Iris needs you", body: "Allow send email?", url: "/conversations/#{@conversation.id}",
                   tag: "conversation-#{@conversation.id}", approval_url: "/approvals/#{card.id}", badge: 1,
                   conversation_id: @conversation.id, invocation_id: card.id, category: "APPROVAL",
                   version: Invocation::Card.new(card).version }, notice)
    assert_no_match(/hotel|Friday|Two nights/, notice.to_json)
    assert @conversation.reload.waiting?
  end

  # The notice's buttons (#78) offer only what the Watch's card offers: Allow
  # once on a small card, Decline on any other approval, each bound to the
  # card's version; nothing for a question, a sign-in or a payment.
  test "a small card's notice can be allowed once or declined; a long one only declined; a question has no buttons" do
    receive("forget_note", { "key" => "trip" }, call_id: "c1")
    small = sole_notice
    card = @conversation.invocations.sole
    assert_equal [ "APPROVAL", @conversation.id, card.id, Invocation::Card.new(card).version ],
      small.values_at(:category, :conversation_id, :invocation_id, :version)
    clear_enqueued_jobs

    receive("send_email", { "to" => [ "hotel@acme.example" ], "subject" => "Notes", "body" => "word " * 400 }, call_id: "c2")
    assert_not Invocation::Card.new(@conversation.invocations.find_by!(call_id: "c2")).small?
    assert_equal "NEEDS_YOU", sole_notice[:category]
    clear_enqueued_jobs

    receive("ask_person", { "question" => "Which hotel?" }, call_id: "c3")
    question = sole_notice
    assert_equal @conversation.id, question[:conversation_id]
    assert_nil question[:category]
    assert_nil question[:version]
  end

  # The phone and the Watch register the same names (ios/Shared/NoticeRoute.swift):
  # a category Rails sends that they don't know shows no buttons at all.
  test "the apps know each category by Rails' own name" do
    swift = Rails.root.join("ios/Shared/NoticeRoute.swift").read
    Conversation::Notifiable::Buttons.constants.each do |name|
      value = Conversation::Notifiable::Buttons.const_get(name)
      assert_includes swift, %(= "#{value}"), "#{name} should be #{value} in NoticeRoute.swift"
    end
  end

  test "a question says itself, the agent's words to the person" do
    receive("ask_person", { "question" => "Which hotel, the Larch or the Linden?" }, call_id: "c1")
    assert_equal "Which hotel, the Larch or the Linden?", sole_notice[:body]
  end

  test "a person with no device hears that the agent needs them by email, from the agent, with the way back" do
    @robin.push_subscriptions.delete_all
    ActionMailer::Base.deliveries.clear
    perform_enqueued_jobs(only: MailDeliveryJob) do
      receive("ask_person", { "question" => "Which hotel, the Larch or the Linden?" }, call_id: "c1")
    end

    assert_no_enqueued_jobs only: Push::DeliveryJob
    mail = ActionMailer::Base.deliveries.sole
    assert_equal [ "robin@example.com" ], mail.to
    assert_equal "Iris <#{@agent.email_address}>", mail[:from].to_s
    assert_equal "Iris needs you", mail.subject
    assert_match "Which hotel, the Larch or the Linden?", mail.body.to_s
    assert_match %r{Answer it here: http://\S+/conversations/#{@conversation.id}}, mail.body.to_s

    ActionMailer::Base.deliveries.clear
    perform_enqueued_jobs(only: MailDeliveryJob) { send_email("c2") }
    assert_no_match(/hotel@acme|Two nights/, ActionMailer::Base.deliveries.sole.body.to_s)
  end

  test "a finished reply says its opening words as plain text, under the agent's name" do
    @conversation.update!(status: "running", execution_status: "running")
    turn("user", "Book Lisbon", 1)
    turn("assistant", "**Booked** the [Friday flight](https://flights.example.com/1) to Lisbon. #{"It leaves at nine. " * 10}", 2)

    @conversation.settle(execution: "idle")

    notice = sole_notice
    assert_equal [ "reply", "Iris", "REPLY", @conversation.id ], notice.values_at(:kind, :title, :category, :conversation_id)
    assert_equal "Booked the Friday flight to Lisbon. It leaves at nine.", notice[:body].first(54)
    assert_operator notice[:body].length, :<=, Conversation::Notifiable::NOTICE_WORDS
    assert_no_match(/flights\.example/, notice[:body])
    assert_equal 0, notice[:badge]
  end

  # #82: a card waiting on the person is priority, sounding even on the Watch;
  # a reply is regular, quiet. An agent its person lowered sends its cards as
  # regular too.
  test "a card's notice is priority and a reply's regular, until the person lowers the agent" do
    send_email("c1")
    assert_equal "priority", sole_notice[:level]
    clear_enqueued_jobs

    @conversation.update!(status: "running", execution_status: "running")
    turn("assistant", "Booked.", 5)
    @conversation.settle(execution: "idle")
    assert_equal "regular", sole_notice[:level]
    clear_enqueued_jobs

    @agent.update!(priority_notifications: false)
    receive("ask_person", { "question" => "Which hotel?" }, call_id: "c2")
    assert_equal [ "needs_you", "regular" ], sole_notice.values_at(:kind, :level)
  end

  test "no notice for a run that said nothing to the person, for one still calling tools, or for the person's own message" do
    @conversation.update!(status: "running", execution_status: "running")
    turn("user", "Check the inbox for anything new", 1)
    @conversation.settle(execution: "idle")

    @conversation.update!(status: "running", execution_status: "running")
    turn("assistant", "Looking.", 2, tool_calls: [ { "id" => "t1", "name" => "list_notes", "arguments" => {} } ])
    @conversation.settle(execution: "idle")

    @conversation.update!(status: "running", execution_status: "running")
    turn("assistant", "", 3)
    @conversation.settle(execution: "idle")

    assert_no_enqueued_jobs(only: Push::DeliveryJob) do
      @conversation.update!(status: "idle", execution_status: "idle")
      turn("user", "Thanks", 4)
      @conversation.settle(execution: "running")
    end
    assert_enqueued_jobs 0, only: Push::DeliveryJob
  end

  test "a run that stops with an error says so once, from the kind of failure, and opens the thread; idle after it says nothing" do
    @conversation.update!(status: "running", execution_status: "running", failure: "rate_limited")
    turn("assistant", "Booked.", 1)
    @conversation.settle(execution: "error")
    @conversation.settle(execution: "error")
    @conversation.settle(execution: "idle")

    assert_equal({ kind: "error", level: "regular", title: "Iris", body: "Stopped: the model's usage limit is reached. Try again later, or switch subscription in settings.",
                   url: "/conversations/#{@conversation.id}", tag: "conversation-#{@conversation.id}", conversation_id: @conversation.id, badge: 0 }, sole_notice)
  end

  # A flaky model fails, something starts another run, and it fails again:
  # one notice until a run ends well or the person writes.
  test "an error is told once until something goes right: again only after a good run, or the person's own message" do
    install_sidecar_settings
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").to_return(status: 202, body: { id: 1 }.to_json)
    stub_request(:get, "#{SIDECAR}/v1/conversations/12/entries").with(query: hash_including({})).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
    @conversation.update!(failure: "rate_limited")
    fail_again = -> { @conversation.settle(execution: "running"); @conversation.settle(execution: "error") }

    fail_again.()
    fail_again.()
    @conversation.receive("Any news?", from: "maya@example.com", via: "Email", answer: "Reply.", request_id: "e-1")
    @conversation.settle(execution: "error")
    assert_equal 1, notices.size, "error, running, error, and mail between: one notice"

    @conversation.settle(execution: "running")
    @conversation.settle(execution: "idle")
    fail_again.()
    assert_equal 2, notices.size, "a run that ended well, then an error: told again"

    @conversation.submit("Try again", request_id: "m-1")
    @conversation.settle(execution: "error")
    assert_equal 3, notices.size, "the person wrote, then an error: told again"
  ensure
    remove_sidecar_settings
  end

  # A failure the app doesn't know by name may carry anything: a provider's
  # message, a path, a key. The notice lands on a lock screen.
  test "an error the app has no words for says only that it stopped, never the failure itself" do
    raw = "provider_said: 401 sk-ant-api03-secret for /home/agent/notes.md"
    @conversation.update!(status: "running", execution_status: "running", failure: raw)
    @conversation.settle(execution: "error")

    notice = sole_notice
    assert_equal "Stopped before finishing. Open the conversation to see why.", notice[:body]
    assert_no_match(/401|sk-ant|secret|notes|provider/, notice.to_json)
  end

  test "nothing is queued without the install's keys, or without a device" do
    with_setting(:web_push, :private_key, nil) { send_email("c1") }
    @robin.push_subscriptions.delete_all
    send_email("c2")
    assert_enqueued_jobs 0, only: Push::DeliveryJob
  end

  test "each card starting or stopping waiting re-broadcasts the badge; working does not" do
    card = nil
    assert_turbo_stream_broadcasts([ @robin, :badge ], count: 1) { card = waiting_card("c1") }
    assert_equal 1, @robin.needs_you_count
    assert_turbo_stream_broadcasts([ @robin, :badge ], count: 1) { waiting_card("c2") }
    assert_equal 2, @robin.needs_you_count
    assert_empty capture_turbo_stream_broadcasts([ @robin, :badge ]) { @conversation.settle(execution: "running") }
    assert_turbo_stream_broadcasts([ @robin, :badge ], count: 1) { card.update!(state: "denied") }
    assert_empty capture_turbo_stream_broadcasts([ @robin, :badge ]) { @conversation.settle(execution: "idle") }
    assert_equal 1, @robin.needs_you_count
  end

  test "a reply is told when the agent's run ends, even while a helper's card still waits on the person" do
    @conversation.settle(execution: "running")
    @conversation.invocations.create!(task_id: "7", call_id: "h/c1", tool_name: "ask_person", arguments: { "question" => "Which?" },
      digest: "d", state: "awaiting_person", expires_at: 1.hour.from_now)
    turn("user", "Book Lisbon", 1)
    turn("assistant", "Booked.", 2)
    clear_enqueued_jobs

    @conversation.settle(execution: "idle")

    assert @conversation.reload.waiting?
    assert_equal [ "reply", "Booked." ], sole_notice.values_at(:kind, :body)
  end

  test "the badge counts the cards Needs you lists: every one waiting on the person in each of their workspaces, not someone else's" do
    waiting_card("c1")
    waiting_card("c2", expires_at: 1.minute.ago)
    club = Workspace.create!(name: "Book club")
    club.memberships.create!(user: @robin, role: "owner")
    waiting_card("c3", conversation: create_conversation(@robin.start_agent("Wren", workspace: club), durable_id: "13"))
    waiting_card("c4", conversation: create_user(name: "Sam").conversations.sole)

    assert_equal 2, @robin.needs_you_count
    assert_equal @robin.needs_you.size, @robin.needs_you_count
    assert_equal %w[ c1 c3 ], @robin.needs_you.map(&:call_id)
  end

  private
    def waiting_card(call_id, conversation: @conversation, expires_at: 1.hour.from_now)
      conversation.invocations.create!(task_id: "7", call_id: call_id, tool_name: "ask_person", arguments: { "question" => "Which?" },
        digest: "d", state: "awaiting_person", expires_at: expires_at)
    end

    def notices = enqueued_jobs.select { it["job_class"] == "Push::DeliveryJob" && it["arguments"].last["kind"] == "error" }

    def sole_notice
      jobs = enqueued_jobs.select { it["job_class"] == "Push::DeliveryJob" }
      assert_equal 1, jobs.size, "one notice"
      ActiveJob::Arguments.deserialize(jobs.sole["arguments"]).then { |user, payload| assert_equal @robin, user; payload }
    end

    def turn(role, content, entry_id, tool_calls: [])
      @conversation.messages.create!(entry_key: "e#{entry_id}", entry_id: entry_id, role: role, content: content, tool_calls: tool_calls)
    end

    def receive(tool, arguments, call_id:)
      payload = invocation_payload(@conversation, tool: tool, arguments: arguments, call_id: call_id)
      Invocation.receive(@conversation, task_id: payload[:taskId], call_id: call_id, tool: tool, arguments: arguments, digest: payload[:digest])
    end

    def send_email(call_id) = receive("send_email", { "to" => [ "hotel@acme.example" ], "subject" => "Friday", "body" => "Two nights." }, call_id: call_id)
end
