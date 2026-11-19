require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/push_test_helper"

# The one gate every notice goes through: each kind passes only while the
# person wants its kind, has a device, and the install has its keys.
class PushTest < ActiveSupport::TestCase
  include AgentTestHelper
  include PushTestHelper
  include ActiveJob::TestHelper

  setup do
    install_push_settings
    @robin = create_user(name: "Robin")
    subscribe(@robin)
  end
  teardown { remove_push_settings }

  test "each kind goes only while its own choice is on" do
    { "reply" => :push_messages, "needs_you" => :push_needs_you, "held" => :push_needs_you,
      "error" => :push_errors, "texts" => :push_errors }.each do |kind, choice|
      %i[ push_messages push_needs_you push_errors ].each do |off|
        @robin.update!(push_messages: true, push_needs_you: true, push_errors: true, off => false)
        clear_enqueued_jobs
        Push.deliver(@robin, kind: kind, title: "Iris", body: "Hi", url: "/", tag: "t")
        assert_equal (off == choice ? 0 : 1), notices.size, "#{kind} with #{off} off"
      end
    end
  end

  test "a notice carries its kind and the badge's count; nothing without a device or keys; an unknown kind is a mistake" do
    Push.deliver(@robin, kind: "reply", title: "Iris", body: "Booked.", url: "/conversations/1", tag: "conversation-1")
    payload = ActiveJob::Arguments.deserialize(notices.sole["arguments"]).last
    assert_equal({ kind: "reply", level: "regular", title: "Iris", body: "Booked.", url: "/conversations/1", tag: "conversation-1", badge: 0 }, payload)

    clear_enqueued_jobs
    with_setting(:web_push, :private_key, nil) { Push.deliver(@robin, kind: "reply", title: "Iris") }
    @robin.push_subscriptions.delete_all
    Push.deliver(@robin, kind: "reply", title: "Iris")
    assert_empty notices
    assert_raises(KeyError) { Push.deliver(@robin, kind: "gossip", title: "Iris") }
  end

  # #82: what needs the person now is priority; the rest is regular. The
  # agent a notice is from can be lowered by its person, and then even its
  # cards are regular. Nothing raises a regular kind.
  test "a card waiting on the person is priority, every other kind regular, and an agent lowered sends regular" do
    agent = @robin.agents.sole
    Push.deliver(@robin, kind: "needs_you", agent: agent, title: "Iris needs you", url: "/", tag: "t")
    Push.deliver(@robin, kind: "needs_you", title: "Iris waits for you", url: "/", tag: "t")
    %w[ reply error held texts ].each { Push.deliver(@robin, kind: it, agent: agent, title: "Iris", url: "/", tag: "t") }
    agent.update!(priority_notifications: false)
    Push.deliver(@robin, kind: "needs_you", agent: agent, title: "Iris needs you", url: "/", tag: "t")

    assert_equal %w[ priority priority regular regular regular regular regular ],
      notices.map { ActiveJob::Arguments.deserialize(it["arguments"]).last[:level] }
  end

  private
    def notices = enqueued_jobs.select { it["job_class"] == "Push::DeliveryJob" }
end
