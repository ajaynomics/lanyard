require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

class Agent::EffectTest < ActiveSupport::TestCase
  include AgentTestHelper

  test "the digest is the sidecar's canonical JSON SHA-256 of the whole call" do
    # Vector from agent/state.mjs digest(): keys sorted at every depth, no spaces.
    arguments = { "key" => "greeting", "body" => "h\u00e9llo \"world\" </script>" }
    digest = Agent::Effect.digest_for(alice_in, task_id: 7, call_id: "tool:1:abc", arguments: arguments)

    assert_equal "8af61f1bebc8684af74b26bdae921e6a359153a0ce62ed9cba33d4670f01c4c7", digest
  end

  test "the same call twice writes once and returns the committed result" do
    payload = effect_payload(alice_in)
    first = record(alice_in, payload)
    second = record(alice_in, payload)

    assert_equal first, second
    assert_equal 1, alice_in.effects.count
    assert_equal 1, alice_in.notes.count
  end

  test "reusing a call identity with different arguments is a conflict and changes nothing" do
    record(alice_in, effect_payload(alice_in))
    changed = effect_payload(alice_in, arguments: { "key" => "greeting", "body" => "changed" })

    assert_raises(Agent::Effect::Conflict) { record(alice_in, changed) }
    assert_equal "hello", alice_in.notes.sole.body
  end

  test "a digest for another scope or other arguments is refused before any write" do
    forged = effect_payload(alice_in("two")).merge(workspaceId: "one")
    tampered = effect_payload(alice_in).merge(arguments: { "key" => "greeting", "body" => "other" })

    assert_raises(Agent::Effect::Conflict) { record(alice_in, forged) }
    assert_raises(Agent::Effect::Conflict) { record(alice_in, tampered) }
    assert_equal 0, alice_in.effects.count
  end

  test "a distinct call identity is a distinct effect" do
    record(alice_in, effect_payload(alice_in))
    record(alice_in, effect_payload(alice_in, call_id: "tool:2:def", arguments: { "key" => "greeting", "body" => "again" }))

    assert_equal 2, alice_in.effects.count
    assert_equal "again", alice_in.notes.sole.body
  end

  private
    def record(access, payload)
      Agent::Effect.record_note!(access, task_id: payload[:taskId], call_id: payload[:callId],
        arguments: payload[:arguments], digest: payload[:digest])
    end
end
