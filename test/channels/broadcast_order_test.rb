require "test_helper"

# A page draws its live changes in the order they were broadcast (#61): a
# script's first call, added before its second, stays above it.
class BroadcastOrderTest < ActiveSupport::TestCase
  test "a broadcast held up on its way to a page still arrives before the one sent after it" do
    subscribed, received = Queue.new, Queue.new
    held_up = ->(message) { sleep 0.3 if message == "first call"; received << message }
    pubsub = ActionCable.server.pubsub
    pubsub.subscribe("thread", held_up, -> { subscribed << true })
    assert subscribed.pop(timeout: 5), "subscribed"

    pubsub.broadcast("thread", "first call")
    pubsub.broadcast("thread", "second call")

    assert_equal [ "first call", "second call" ], 2.times.map { received.pop(timeout: 5) }
  ensure
    pubsub&.unsubscribe("thread", held_up)
  end
end
