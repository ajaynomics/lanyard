module Agent
  class Note < ApplicationRecord
    scope :owned_by, ->(access) { where(actor_id: access.actor_id, workspace_id: access.workspace_id) }
    validates :actor_id, :workspace_id, :key, presence: true
    validates :key, length: { maximum: 64 }
    validates :body, length: { maximum: 16_384 }
  end
end
