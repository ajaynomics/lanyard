# What a skill and a saved prompt share: a named body, kept by the agent as
# part of what it is, so each change is a revision of the agent.
module Agent::Part
  extend ActiveSupport::Concern

  # pi's rule for a skill's or a prompt's name: lowercase letters, digits, single hyphens.
  NAME = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
  LIMIT = 32
  BODY_BYTES = 32.kilobytes

  included do
    belongs_to :agent
    broadcasts_refreshes_to :agent

    after_save :revise_agent
    after_destroy :revise_agent

    normalizes :description, with: -> { it.to_s.squish }
    validates :name, length: { maximum: 64 }, uniqueness: { scope: :agent_id },
      format: { with: NAME, message: "may use only a-z, 0-9 and single hyphens" }
    validates :description, length: { maximum: 1_024 }
    validates :body, presence: true
    validate :body_fits
    validate :agent_has_room, on: :create
  end

  def snapshot = { "name" => name, "description" => description, "body" => body }

  private
    def body_fits
      errors.add(:body, "must be #{BODY_BYTES / 1.kilobyte} KB or smaller") if body.to_s.bytesize > BODY_BYTES
    end

    def agent_has_room
      errors.add(:base, "#{agent} already has #{LIMIT} #{model_name.plural}") if agent && agent.public_send(model_name.plural).count >= LIMIT
    end

    def revise_agent = agent.record_revision
end
