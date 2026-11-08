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
    assert_equal({ kind: "needs_you", title: "Iris needs you", body: "Allow send email?", url: "/conversations/#{@conversation.id}",
                   tag: "conversation-#{@conversation.id}", badge: 1 }, notice)
    assert_no_match(/hotel|Friday|Two nights/, notice.to_json)
    assert @conversation.reload.waiting?
  end

  test "a question says itself, the agent's words to the person" do
    receive("ask_person", { "question" => "Which hotel, the Larch or the Linden?" }, call_id: "c1")
    assert_equal "Which hotel, the Larch or the Linden?", sole_notice[:body]
  end

  test "a finished reply says its opening words as plain text, under the agent's name" do
    @conversation.update!(status: "running")
    turn("user", "Book Lisbon", 1)
    turn("assistant", "**Booked** the [Friday flight](https://flights.example.com/1) to Lisbon. #{"It leaves at nine. " * 10}", 2)

    @conversation.mark("idle")

    notice = sole_notice
    assert_equal [ "reply", "Iris" ], notice.values_at(:kind, :title)
    assert_equal "Booked the Friday flight to Lisbon. It leaves at nine.", notice[:body].first(54)
    assert_operator notice[:body].length, :<=, Conversation::Notifiable::NOTICE_WORDS
    assert_no_match(/flights\.example/, notice[:body])
    assert_equal 0, notice[:badge]
  end

  test "no notice for a run that said nothing to the person, for one still calling tools, or for the person's own message" do
    @conversation.update!(status: "running")
    turn("user", "Check the inbox for anything new", 1)
    @conversation.mark("idle")

    @conversation.update!(status: "running")
    turn("assistant", "Looking.", 2, tool_calls: [ { "id" => "t1", "name" => "list_notes", "arguments" => {} } ])
    @conversation.mark("idle")

    @conversation.update!(status: "running")
    turn("assistant", "", 3)
    @conversation.mark("idle")

    assert_no_enqueued_jobs(only: Push::DeliveryJob) do
      @conversation.update!(status: "idle")
      turn("user", "Thanks", 4)
      @conversation.mark("running")
    end
    assert_enqueued_jobs 0, only: Push::DeliveryJob
  end

  test "a run that stops with an error, and a thread already idle, say nothing" do
    @conversation.update!(status: "running")
    turn("assistant", "Booked.", 1)
    @conversation.mark("error")
    @conversation.mark("idle")
    assert_enqueued_jobs 0, only: Push::DeliveryJob
  end

  test "nothing is queued without the install's keys, or without a device" do
    with_setting(:web_push, :private_key, nil) { send_email("c1") }
    @robin.push_subscriptions.delete_all
    send_email("c2")
    assert_enqueued_jobs 0, only: Push::DeliveryJob
  end

  test "starting and stopping waiting re-broadcasts the badge; working does not" do
    assert_turbo_stream_broadcasts([ @robin, :badge ], count: 1) { @conversation.mark("waiting") }
    assert_equal 1, @robin.agents_needing_you
    assert_turbo_stream_broadcasts([ @robin, :badge ], count: 1) { @conversation.mark("running") }
    assert_empty capture_turbo_stream_broadcasts([ @robin, :badge ]) { @conversation.mark("idle") }
    assert_equal 0, @robin.agents_needing_you
  end

  test "the badge counts agents waiting on the person, not archived ones, not branches twice, not someone else's" do
    @conversation.update!(status: "waiting")
    second = create_conversation(@agent, durable_id: "13")
    second.update!(status: "waiting")
    @agent.conversations.create!(user: @robin, parent: @conversation, root: @conversation, request_id: "b1", status: "waiting")
    create_user(name: "Sam").conversations.sole.update!(status: "waiting")
    assert_equal 2, @robin.agents_needing_you
    second.archive
    assert_equal 1, @robin.agents_needing_you
  end

  private
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
