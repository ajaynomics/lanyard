# A signed review binds the exact old text, current revision and reviewing
# person. The new revision consumes that review, even if the text later returns.
class InstructionRestoration
  class Stale < StandardError; end
  Preview = Data.define(:details, :token)

  def initialize(target:, workspace:, by:)
    @target, @workspace, @reviewer = target, workspace, by
  end

  def revision_page(before:, limit:)
    @target.with_lock do
      reviewer_membership!
      revisions = approved_revisions.unscope(:order).includes(approval: :invocation)
      revisions = revisions.where(id: ...before) if before
      # Only what the review page accepts, so no listed link is a 404.
      revisions.find_each(order: :desc).lazy.select { restorable?(it) }.first(limit).map { [ it.id, it.created_at ] }
    end
  end

  def preview(revision_id)
    @target.with_lock do
      membership = reviewer_membership!
      source = source_revision!(revision_id)
      token = verifier.generate(fingerprint(source, membership), expires_in: 15.minutes) unless @target.instructions == source.instructions
      Preview.new(details: InstructionsChange.new(@target.instructions, source.instructions).details, token: token)
    end
  end

  def restore!(revision_id, token:)
    reviewed = verifier.verified(token) if token.is_a?(String)
    @target.with_lock do
      membership = reviewer_membership!
      source = source_revision!(revision_id)
      raise Stale unless reviewed == fingerprint(source, membership) && @target.instructions != source.instructions
      raise Stale unless @target.class.normalize_value_for(:instructions, source.instructions) == source.instructions

      if personal?
        @target.change_instructions(source.instructions, approval: source.approval, restored_by: @reviewer, restored_from: source)
      else
        @target.change_instructions(source.instructions, by: @reviewer, approval: source.approval, restored_from: source)
      end
    end
  end

  private
    def personal? = @target.is_a?(Agent)

    def approved_revisions
      revisions = @target.revisions.with_instruction_approval
      personal? ? revisions.where(instruction_workspace_id: @workspace.id) : revisions
    end

    def source_revision!(id)
      approved_revisions.find(id).tap { raise ActiveRecord::RecordNotFound unless restorable?(it) }
    end

    def restorable?(revision) = revision.approved_text_for?(@target, workspace: @workspace)

    def reviewer_membership!
      target_workspace = personal? ? @target.workspace : @target
      raise ActiveRecord::RecordNotFound unless target_workspace == @workspace

      membership = @workspace.memberships.find_by!(user: @reviewer)
      raise ActiveRecord::RecordNotFound unless personal? || membership.owner?

      membership
    end

    def fingerprint(source, membership)
      revision_id = @target.revisions.reorder(id: :desc).pick(:id)
      Digest::SHA256.hexdigest([
        @target.class.name, @target.id, @workspace.id, revision_id, Digest::SHA256.hexdigest(@target.instructions),
        @target.updated_at.utc.iso8601(6), source.id, source.approval_id, Digest::SHA256.hexdigest(source.instructions),
        @reviewer.id, membership.id, membership.role, membership.updated_at.utc.iso8601(6)
      ].to_json)
    end

    def verifier = Rails.application.message_verifier(:instruction_restoration)
end
