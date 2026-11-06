module Agent
  class Conversation < ApplicationRecord
    # What the page may show. The sidecar's snapshot also carries raw Durable
    # state and scheduler inspection, which never reach a browser.
    SNAPSHOT_KEYS = %w[id entries pendingInputs status failure usage].freeze

    scope :owned_by, ->(access) { where(actor_id: access.actor_id, workspace_id: access.workspace_id) }
    validates :actor_id, :workspace_id, :request_id, :durable_id, presence: true

    def snapshot(access)
      raw = DurableAssistants::PiDurable::Client.new.snapshot(access, durable_id)
      raw.slice(*SNAPSHOT_KEYS).tap do |view|
        view["entries"] = Array(view["entries"]).map { |entry| entry.slice("id", "role", "content", "toolName", "isError") }
        view["pendingInputs"] = Array(view["pendingInputs"])
        # Why the newest run ended without an answer: a fixed reason category only.
        view["failure"] = view["failure"].is_a?(Hash) ? view["failure"].slice("reason") : nil
      end
    end
  end
end
