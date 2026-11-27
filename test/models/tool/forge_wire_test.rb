require "test_helper"

class Tool::ForgeWireTest < ActiveSupport::TestCase
  WIRE = Tool::Forge::Wire
  SHA = "a" * 40
  DIGEST = "a" * 64
  PUSH = { "verb" => "push", "repo" => "sample/project", "branch" => "review/topic", "expected_head" => "absent", "revision" => SHA }.freeze
  UUID = "11111111-1111-4111-8111-111111111111"

  test "the v2 bounds include the disabled file verbs without enabling them" do
    assert_equal %w[ pr diff fetch ci-runs ci-jobs ci-log ci-artifact push ], Tool::Forge.arguments.fetch("verb").fetch("enum")
    assert_equal({ "fetch" => 120, "push" => 120 }, WIRE::VERBS.transform_values(&:timeout).select { |_, seconds| seconds != 30 })
    assert_equal [ 256.kilobytes, 50.megabytes, :max_bytes, 10.megabytes ], WIRE::VERBS.values.filter_map(&:reply_frame)
    assert_equal [ 50.megabytes ], WIRE::VERBS.values.filter_map(&:request_frame)
  end

  test "push receipt requires exact context, byte echo and bundle digest and size" do
    challenge = "a" * 32
    reply = PUSH.slice("verb", "repo").merge("status" => "pushed", "operation" => PUSH, "challenge" => challenge,
      "receipt_id" => UUID, "bundle_bytes" => 500, "bundle_sha256" => DIGEST)
    sent_operation_json = JSON.generate(PUSH)
    check = ->(response, echo: sent_operation_json) do
      Tool::Forge::Receipt.confirmed(response, challenge:, operation: PUSH, sent_operation_json:, echoed_operation_json: echo,
        bundle_bytes: 500, bundle_sha256: DIGEST)
    end
    assert_equal reply.slice("status", "receipt_id", "bundle_bytes", "bundle_sha256"), check.call(reply)
    assert_nil check.call(reply, echo: JSON.pretty_generate(PUSH))
    assert_nil check.call(reply, echo: nil)
    { "verb" => "diff", "repo" => "sample/other", "challenge" => "b" * 32, "receipt_id" => "malformed", "bundle_bytes" => 501,
      "bundle_sha256" => "b" * 64, "operation" => PUSH.merge("expected_head" => SHA), "extra" => true }.each do |key, value|
      assert_nil check.call(reply.merge(key => value)), key
    end
    assert_nil check.call(reply.except("bundle_sha256"))
  end

  test "failures have only the permitted status, reason and echo fields" do
    reply = PUSH.slice("verb", "repo").merge("status" => "error", "reason" => "moved")
    assert WIRE.failure?(PUSH, reply)
    refute WIRE.failure?(PUSH, reply.merge("status" => "refused"))
    assert WIRE.failure?(PUSH, reply.except("repo").merge("status" => "refused", "reason" => "peer"))
    refute WIRE.failure?(PUSH, reply.merge("repo" => "sample/other"))
    refute WIRE.failure?(PUSH, reply.merge("reason" => "custom"))
    refute WIRE.failure?(PUSH, reply.merge("verb" => "diff"))
    refute WIRE.failure?(PUSH, reply.merge("message" => "For this call"))
  end

  test "CI replies validate every nested key, count, enum and requested selector" do
    operation = { "verb" => "ci-jobs", "run_id" => 42, "repo" => "sample/project" }
    step = { "name" => "test", "conclusion" => nil }
    job = { "job_id" => 7, "name" => "test", "status" => "completed", "conclusion" => "success", "steps" => [ step ] }
    reply = operation.merge("status" => "ok", "jobs" => [ job ])
    assert_equal reply, Tool::Forge::ReadResult.confirmed(operation, reply, nil)
    [ job.merge("status" => "success"), job.merge("extra" => "ignored"), job.merge("job_id" => 0),
      job.merge("steps" => [ step.merge("conclusion" => "completed") ]), job.merge("steps" => [ step ] * 101) ].each do |invalid|
      assert_nil Tool::Forge::ReadResult.confirmed(operation, reply.merge("jobs" => [ invalid ]), nil)
    end
    assert_nil Tool::Forge::ReadResult.confirmed(operation, reply.merge("jobs" => [ job ] * 51), nil)
    assert_nil Tool::Forge::ReadResult.confirmed(operation, reply.merge("run_id" => 43), nil)
  end
end
