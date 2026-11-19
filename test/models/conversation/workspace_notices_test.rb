require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/email_test_helper"
require_relative "../../test_helpers/push_test_helper"

# In a shared workspace what an agent asks or says reaches every member, each
# on their own devices with their own badge, once each; nobody outside it.
# Alice made the agent; Bob is a member; Carol is in no shared workspace.
class Conversation::WorkspaceNoticesTest < ActiveSupport::TestCase
  include AgentTestHelper
  include EmailTestHelper
  include PushTestHelper
  include ActiveJob::TestHelper

  setup do
    install_email_settings
    install_push_settings
    @alice, @bob, @carol = %w[ Alice Bob Carol ].map { create_user(name: it) }
    @shared = Workspace.create!(name: "Household")
    @shared.memberships.create!(user: @alice, role: "owner")
    @bobs_membership = @shared.memberships.create!(user: @bob, role: "member")
    @agent = @alice.start_agent("Iris", workspace: @shared)
    @conversation = create_conversation(@agent)
    [ @alice, @bob, @carol ].each { subscribe(it, endpoint: "https://fcm.googleapis.com/fcm/send/#{it.name.downcase}") }
  end
  teardown do
    remove_email_settings
    remove_push_settings
  end

  test "a card waiting reaches the maker and a member, once each, with their own badge; never a non-member" do
    create_conversation(@bob.personal_workspace.agents.sole, durable_id: "20").invocations.create!(task_id: "7", call_id: "own",
      tool_name: "ask_person", arguments: { "question" => "Which?" }, digest: "d", state: "awaiting_person", expires_at: 1.hour.from_now)
    clear_enqueued_jobs

    broadcasts = capture_badges { waiting_card }

    assert_equal({ @alice => 1, @bob => 2 }, notices.to_h { |user, payload| [ user, payload[:badge] ] })
    assert_equal [ "Iris needs you" ], notices.map { it.last[:title] }.uniq
    assert_equal({ @alice => 1, @bob => 1, @carol => 0 }, broadcasts)
  end

  test "a finished reply and an error reach every member, and nobody else" do
    @conversation.update!(status: "running", execution_status: "running", failure: "rate_limited")
    @conversation.messages.create!(entry_key: "e1", entry_id: 1, role: "user", content: "Book Lisbon")
    @conversation.messages.create!(entry_key: "e2", entry_id: 2, role: "assistant", content: "Booked.")
    @conversation.settle(execution: "idle")
    assert_equal [ [ @alice, "reply" ], [ @bob, "reply" ] ], notices.map { |user, payload| [ user, payload[:kind] ] }.sort_by { it.first.id }

    clear_enqueued_jobs
    @conversation.settle(execution: "error")
    assert_equal [ @alice, @bob ], notices.map(&:first).sort_by(&:id)
  end

  test "a member with no device hears by email, at their own address" do
    @bob.push_subscriptions.delete_all
    ActionMailer::Base.deliveries.clear
    perform_enqueued_jobs(only: MailDeliveryJob) { waiting_card }

    assert_equal [ @alice ], notices.map(&:first)
    assert_equal [ [ "bob@example.com" ] ], ActionMailer::Base.deliveries.map(&:to)
  end

  test "a removed member stops hearing and stops seeing the badge" do
    waiting_card.update!(state: "denied")
    assert_includes notices.map(&:first), @bob
    clear_enqueued_jobs
    @bobs_membership.destroy!

    broadcasts = capture_badges { waiting_card(call_id: "c2") }

    assert_equal [ @alice ], notices.map(&:first)
    assert_equal({ @alice => 1, @bob => 0, @carol => 0 }, broadcasts)
    assert_equal 0, @bob.needs_you_count
  end

  test "an agent's texts paused for the day are told to every member" do
    invocation = @conversation.invocations.create!(task_id: "7", call_id: "c1", tool_name: "send_text", arguments: {}, digest: "d", state: "running")
    Tool::SendText.new(invocation).send(:tell_person)
    assert_equal [ [ @alice, "texts" ], [ @bob, "texts" ] ], notices.map { |user, payload| [ user, payload[:kind] ] }.sort_by { it.first.id }
  end

  private
    def waiting_card(call_id: "c1")
      @conversation.invocations.create!(task_id: "7", call_id: call_id, tool_name: "ask_person", arguments: { "question" => "Which?" },
        digest: "d", state: "awaiting_person", expires_at: 1.hour.from_now)
    end

    def notices
      enqueued_jobs.select { it["job_class"] == "Push::DeliveryJob" }.map { ActiveJob::Arguments.deserialize(it["arguments"]) }
    end

    # How many badge broadcasts each person's stream got.
    def capture_badges(&block)
      counts = {}
      [ @alice, @bob, @carol ].reduce(block) do |inner, person|
        -> { counts[person] = capture_turbo_stream_broadcasts([ person, :badge ]) { inner.call }.size }
      end.call
      counts
    end
end
