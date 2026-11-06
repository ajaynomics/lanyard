require "digest"
require "json"

module Agent
  # The Rails-owned effect ledger. One row per (scope, task, call): the sidecar
  # may call again after a crash, before or after this transaction committed,
  # and gets the committed result back instead of a second write.
  class Effect < ApplicationRecord
    class Conflict < StandardError; end

    CALL_ID = %r{\A[\w.:|+/=-]{1,512}\z}

    scope :owned_by, ->(access) { where(actor_id: access.actor_id, workspace_id: access.workspace_id) }
    validates :actor_id, :workspace_id, :task_id, :call_id, :argument_digest, presence: true

    # The sidecar's canonical JSON: object keys sorted at every depth, no spaces.
    def self.canonical(value)
      case value
      when Hash then "{#{value.keys.map(&:to_s).sort.map { |key| "#{JSON.generate(key)}:#{canonical(value.fetch(key) { value.fetch(key.to_sym) })}" }.join(',')}}"
      when Array then "[#{value.map { |item| canonical(item) }.join(',')}]"
      else JSON.generate(value)
      end
    end

    # The digest binds the whole call (who, where, which call, which arguments),
    # not just the arguments, so a replay cannot move a write to another scope.
    def self.digest_for(access, task_id:, call_id:, arguments:)
      Digest::SHA256.hexdigest(canonical(
        "actorId" => access.actor_id, "workspaceId" => access.workspace_id,
        "taskId" => task_id, "callId" => call_id, "tool" => "rails_note", "arguments" => arguments
      ))
    end

    def self.record_note!(access, task_id:, call_id:, arguments:, digest:)
      raise Conflict unless task_id.is_a?(Integer) || (task_id.is_a?(String) && Access.valid_id?(task_id))
      raise Conflict unless call_id.is_a?(String) && call_id.match?(CALL_ID)
      raise Conflict unless arguments.is_a?(Hash) && arguments.keys.sort == %w[body key]
      key, body = arguments.values_at("key", "body")
      raise Conflict unless key.is_a?(String) && key.match?(/\A[\w.-]{1,64}\z/) &&
        body.is_a?(String) && body.bytesize.between?(1, 16_384)
      expected = digest_for(access, task_id: task_id, call_id: call_id, arguments: arguments)
      raise Conflict unless digest.is_a?(String) && ActiveSupport::SecurityUtils.secure_compare(expected, digest)

      transaction do
        # Write first, so competing SQLite callers serialize before reading a note.
        # No remote call or external effect occurs inside this transaction.
        record = access.effects.create!(task_id: task_id.to_s, call_id: call_id, argument_digest: expected)
        note = access.notes.find_or_initialize_by(key: key)
        note.update!(body: body)
        result = { "noteId" => note.id, "key" => note.key, "body" => note.body }
        record.update!(result: result)
        result
      end
    rescue ActiveRecord::RecordNotUnique
      record = access.effects.find_by!(task_id: task_id.to_s, call_id: call_id)
      raise Conflict unless record.argument_digest == expected && record.result.is_a?(Hash)
      record.result
    end
  end
end
