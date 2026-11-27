# A kept copy of an agent's or a workspace's instructions, with who allowed it
# and through which call. History moves with an agent, so it keeps the original
# workspace too.
module InstructionRevision
  extend ActiveSupport::Concern

  included do
    belongs_to :approval, optional: true

    scope :with_instruction_approval, -> { joins(:approval).where(approvals: { decision: "approve" }) }

    before_create :record_approved_digest, if: :approval
  end

  # Whether a person allowed exactly this text for this target in this
  # workspace, through a call that then ran (InstructionRestoration).
  def approved_text_for?(target, workspace:)
    approval&.decision == "approve" && approval.invocation.succeeded? &&
      approved_place == [ target, workspace ] && approved_digest == Digest::SHA256.hexdigest(instructions)
  end

  private
    # The call's preview is pruned; keep the digest only if the proposal
    # was for this target in this workspace.
    def record_approved_digest
      self.approved_digest = proposed_digest
    end

    def proposed_digest
      snapshot = approval.invocation.preview&.dig(Tool::ChangeYourself::Proposal::KEY)
      target, workspace = approved_place
      scope = target.is_a?(Agent) ? "yourself" : "workspace"
      snapshot["result_digest"] if snapshot&.dig("base")&.values_at("scope", "target_id", "workspace_id") == [ scope, target.id, workspace&.id ]
    end
end
