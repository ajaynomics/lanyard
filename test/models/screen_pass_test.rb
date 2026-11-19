require "test_helper"
require_relative "../test_helpers/agent_test_helper"

class ScreenPassTest < ActiveSupport::TestCase
  include AgentTestHelper

  setup do
    @owner = create_user
    @conversation = create_conversation(@owner.agents.sole)
  end

  test "a link is found by its token, never by anything kept, and opens for the first device alone" do
    pass, token = ScreenPass.issue!(@conversation, by: @owner)
    assert_equal pass, ScreenPass.find_by_token(token)
    assert_nil ScreenPass.find_by_token(pass.token_digest)
    assert_nil ScreenPass.find_by_token(nil)

    key = pass.open!
    assert key
    assert pass.viewer?(key)
    assert_nil ScreenPass.find(pass.id).open!, "a second device gets nothing" # tenancy-ok: the test's own pass
    assert_not pass.viewer?("other")
    assert_not pass.viewer?(nil)
  end

  test "it is live until it expires or ends" do
    pass, = ScreenPass.issue!(@conversation, by: @owner)
    assert pass.live?
    pass.end!
    assert_not pass.reload.live?
    assert_equal :ended, pass.why_over

    later, = ScreenPass.issue!(@conversation, by: @owner)
    travel ScreenPass::LASTS + 1.second
    assert_not later.live?
    assert_equal :expired, later.why_over
    assert_nil later.open!
  end

  # The relay ends the moment its pass does, not only when the page closes.
  test "a relay watched by a pass is cut once the pass ends" do
    pass, = ScreenPass.issue!(@conversation, by: @owner)
    browser = Class.new { attr_reader :closed; def read = sleep(10); def write(*) = nil; def flush = nil; def close = @closed = true }.new
    computer = Class.new { def read = sleep(10); def write(*) = nil; def flush = nil }.new
    relay = Object.new.extend(ScreenRelay)

    Sync do |task|
      task.async { sleep 0.05; pass.end! }
      task.with_timeout(3) { relay.send(:relay, browser, computer, check_every: 0.02) { pass.reload.live? } }
    end
    assert browser.closed
  end
end
