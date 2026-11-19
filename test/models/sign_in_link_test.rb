require "test_helper"
require_relative "../test_helpers/agent_test_helper"

class SignInLinkTest < ActiveSupport::TestCase
  include AgentTestHelper
  include ActiveJob::TestHelper

  setup do
    @owner = create_user
    @conversation = create_conversation(@owner.agents.sole)
    @invocation = @conversation.invocations.create!(task_id: "7", call_id: "toolu_1", tool_name: "ask_outside_for_sign_in",
      arguments: { "name" => "Bank" }, digest: "d", state: "running")
  end

  test "it is found by its token, never by anything kept, and its end is due in 30 minutes, after any write begun by then" do
    link, token = SignInLink.issue!(@invocation, entry_id: "7f0c", name: "Bank")
    assert_equal link, SignInLink.find_by_token(token)
    assert_nil SignInLink.find_by_token(link.token_digest)
    assert_nil SignInLink.find_by_token(nil)
    assert_nil SignInLink.find_by_token("short")
    assert_in_delta 30.minutes.from_now, link.expires_at, 5
    assert_enqueued_with(job: SignInLinkExpiryJob, args: [ link ], at: link.expires_at + SignInLink::WRITE_LIMIT)
  end

  # Two submits at once each load the link as open; one update claims it.
  test "two copies loaded before either claims it: only one may write" do
    link, = SignInLink.issue!(@invocation, entry_id: "7f0c", name: "Bank")
    first, second = 2.times.map { @conversation.sign_in_links.find(link.id) }
    assert first.open?
    assert second.open?
    assert first.claim
    assert_not second.claim
    assert_equal :used, second.reload.why_refused
  end

  test "why it is refused: used, expired or revoked" do
    link, = SignInLink.issue!(@invocation, entry_id: "7f0c", name: "Bank")
    assert_nil link.why_refused
    assert link.revoke(by: @owner)
    assert_equal :revoked, link.why_refused
    assert_not link.revoke(by: @owner), "once"

    later, = SignInLink.issue!(@invocation, entry_id: "7f0c", name: "Bank")
    travel SignInLink::LASTS + 1.second
    assert_equal :expired, later.why_refused
    assert_not later.claim
  end

  test "expiring one nobody used tells the agent once; one already used or revoked is left as it ended" do
    used, = SignInLink.issue!(@invocation, entry_id: "7f0c", name: "Bank")
    used.claim
    used.update!(outcome: "filled")
    unused, = SignInLink.issue!(@invocation, entry_id: "7f0c", name: "Bank")
    travel SignInLink::LASTS + 1.second

    assert_enqueued_jobs 1, only: SignInLinkReportJob do
      unused.expire
      unused.expire
      used.expire
    end
    assert_equal "expired", unused.reload.outcome
    assert_equal "filled", used.reload.outcome
  end

  test "a link used with no outcome is left alone while a write may still be going, then is lost" do
    link, = SignInLink.issue!(@invocation, entry_id: "7f0c", name: "Bank")
    travel SignInLink::LASTS - 1.second
    assert link.claim
    travel 2.seconds
    link.expire
    assert_nil link.reload.outcome, "a write begun in time may still land"
    travel SignInLink::WRITE_LIMIT
    link.expire
    assert_equal "lost", link.reload.outcome
    assert_match "whether the entry was filled is not known", link.report
  end
end
