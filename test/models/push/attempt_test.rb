require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

# What became of turning on the phone app's notifications: one line in the
# log each, and only each person's latest few kept.
class Push::AttemptTest < ActiveSupport::TestCase
  include AgentTestHelper

  setup { @robin = create_user(name: "Robin") }

  test "each is logged with its code and the app's version, and only the latest are kept, each person's own" do
    other = create_user(name: "Sam").push_attempts.create!(outcome: "no_answer")
    log = StringIO.new
    Rails.logger.broadcast_to(listener = ActiveSupport::Logger.new(log))
    @robin.push_attempts.create!(outcome: "failed", code: 3000, user_agent: "NativeSignIn/1; APNs/production; Lanyard/0.1(12); Hotwire Native iOS")
    Rails.logger.stop_broadcasting_to(listener)
    assert_match "Push attempt: failed (3000) user=#{@robin.id} app=0.1(12)", log.string

    (Push::Attempt::KEPT + 4).times { @robin.push_attempts.create!(outcome: "no_answer", code: it) }

    assert_equal (4...Push::Attempt::KEPT + 4).to_a, @robin.push_attempts.order(:id).pluck(:code)
    assert other.reload
  end

  test "only the outcomes Turn on has" do
    assert_not @robin.push_attempts.build(outcome: "maybe").valid?
    assert_nil @robin.push_attempts.build(outcome: "no_answer", user_agent: "Mozilla/5.0").app_version
  end
end
