module Tool::Forge::Wire
  SHA = /\A[0-9a-f]{40}\z/
  DIGEST = /\A[0-9a-f]{64}\z/
  NONZERO_SHA = /\A(?!0{40}\z)[0-9a-f]{40}\z/
  REF = %r{\A[A-Za-z0-9][A-Za-z0-9._/-]{0,199}\z}
  BRANCH = %r{\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}(?:/[A-Za-z0-9][A-Za-z0-9_-]{0,63}){1,4}\z}
  NAME = /\A[A-Za-z0-9._-]{1,100}\z/
  UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
  CHALLENGE = /\A[0-9a-f]{32}\z/
  REASONS = %w[ agent peer repo branch verb bounds busy rate too_large secret_shaped unsafe_path not_found moved not_ff identity bundle forge_error timeout unknown ].freeze
  STATUS = %w[ queued in_progress completed waiting unknown ].freeze
  CONCLUSION = %w[ success failure cancelled skipped neutral timed_out action_required ].push(nil).freeze
  BOOL = [ true, false ].freeze
  ID = 1..10**12
  NUMBER = 1..10**7
  PATCH_LIMIT = 256.kilobytes
  BUNDLE_LIMIT = 50.megabytes
  ARTIFACT_LIMIT = 10.megabytes

  RUN = { run_id: ID, workflow: String, event: String, status: STATUS, conclusion: CONCLUSION, attempt: :positive }.freeze
  STEP = { name: String, conclusion: CONCLUSION }.freeze
  JOB = { job_id: ID, name: String, status: STATUS, conclusion: CONCLUSION, steps: :steps }.freeze

  Verb = Data.define(:input, :reply, :delivery, :reply_frame, :request_frame, :timeout, :success)
  # One table owns the wire vocabulary; workspace delivery is deliberately off.
  VERBS = {
    "pr" => Verb.new({ number: NUMBER }, { number: NUMBER, state: %w[ open closed merged ], base: :ref, head_ref: :ref,
      head_sha: SHA, mergeable: [ true, false, nil ], title: :title }, :metadata, nil, nil, 30, "ok"),
    "diff" => Verb.new({ base: :ref, head: :ref }, { base_sha: SHA, head_sha: SHA, files: :count, additions: :count,
      deletions: :count, bytes: 0..PATCH_LIMIT, sha256: DIGEST }, :inline, PATCH_LIMIT, nil, 30, "ok"),
    "fetch" => Verb.new({ ref: :ref, have: :have }, { ref: :ref, ref_sha: SHA, bytes: 0..BUNDLE_LIMIT, sha256: DIGEST },
      :workspace, BUNDLE_LIMIT, nil, 120, "ok"),
    "ci-runs" => Verb.new({ head_sha: SHA }, { head_sha: SHA, runs: :runs }, :metadata, nil, nil, 30, "ok"),
    "ci-jobs" => Verb.new({ run_id: ID }, { run_id: ID, jobs: :jobs }, :metadata, nil, nil, 30, "ok"),
    "ci-log" => Verb.new({ job_id: ID, max_bytes: 1..PATCH_LIMIT, tail: BOOL }, { job_id: ID, bytes: 0..PATCH_LIMIT,
      sha256: DIGEST, truncated: BOOL }, :workspace, :max_bytes, nil, 30, "ok"),
    "ci-artifact" => Verb.new({ run_id: ID, name: NAME }, { run_id: ID, name: NAME, bytes: 0..ARTIFACT_LIMIT,
      sha256: DIGEST, entries: 0..1_000 }, :workspace, ARTIFACT_LIMIT, nil, 30, "ok"),
    "push" => Verb.new({ branch: BRANCH, expected_head: :expected_head, revision: NONZERO_SHA }, { receipt_id: UUID,
      challenge: CHALLENGE, operation: Hash, bundle_bytes: 1..BUNDLE_LIMIT, bundle_sha256: DIGEST },
      :workspace, nil, BUNDLE_LIMIT, 120, "pushed")
  }.freeze

  module_function

  def allowed?(operation)
    return false unless operation.is_a?(Hash) && (verb = VERBS[operation["verb"]])
    shape?(operation, verb.input.merge(verb: String, repo: String))
  end

  def success?(operation, reply)
    verb = VERBS.fetch(operation.fetch("verb"))
    shape?(reply, verb.reply.merge(status: [ verb.success ], verb: [ operation["verb"] ], repo: [ operation["repo"] ]))
  end

  def failure?(operation, reply)
    return false if operation["verb"] == "push" && reply.is_a?(Hash) && reply.values_at("status", "reason") == %w[ refused moved ]

    fields = { status: %w[ refused error ], verb: [ operation["verb"] ], reason: REASONS }
    fields = fields.merge(repo: [ operation["repo"] ]) if reply.is_a?(Hash) && reply.key?("repo")
    shape?(reply, fields)
  end

  def shape?(value, fields)
    value.is_a?(Hash) && value.size == fields.size && fields.all? { |key, rule|
      value.key?(key.to_s) && fits?(value[key.to_s], rule)
    }
  end

  def fits?(value, rule)
    case rule
    when Range then value.is_a?(Integer) && rule.cover?(value)
    when Regexp then value.is_a?(String) && rule.match?(value)
    when Array then rule.include?(value)
    when Class then value.is_a?(rule)
    when :expected_head then value == "absent" || fits?(value, NONZERO_SHA)
    when :ref then ref?(value)
    when :positive then value.is_a?(Integer) && value.positive?
    when :count then value.is_a?(Integer) && !value.negative?
    when :title then value.is_a?(String) && value.length <= 200
    when :have then list?(value, 32) { |id| fits?(id, SHA) }
    when :runs then list?(value, 20) { |run| shape?(run, RUN) }
    when :jobs then list?(value, 50) { |job| shape?(job, JOB) }
    when :steps then list?(value, 100) { |step| shape?(step, STEP) }
    end
  end

  def ref?(value)
    fits?(value, REF) && !value.end_with?("/") && %w[ .. @{ // ].none? { |part| value.include?(part) } &&
      value.split("/").none? { |part| part.end_with?(".lock") }
  end

  def list?(value, limit, &block) = value.is_a?(Array) && value.size <= limit && value.all?(&block)
end
