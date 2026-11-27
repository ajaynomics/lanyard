# The signed-in owner's written approval is for one setup, not an operator role.
class Workspace::AgentSetup < ApplicationRecord
  class Conflict < StandardError; end

  APPROVAL_FIELDS = %i[ operator_id name manager_id instructions authorization request_id ].freeze
  HANDOFF_CHANNEL = "Manager handoff"

  belongs_to :workspace
  belongs_to :approved_by, class_name: "User"
  belongs_to :operator, class_name: "User"
  belongs_to :agent, optional: true
  belongs_to :revoked_by, class_name: "User", optional: true
  belongs_to :undone_by, class_name: "User", optional: true

  normalizes :name, with: -> { it.squish }
  normalizes :instructions, with: -> { it.sub(Agent::IDENTITY_HEADER, "") }
  validates :name, :instructions, :authorization, presence: true
  validates :name, length: { maximum: 200 }
  validates :authorization, length: { maximum: 4_000 }
  validates :request_id, format: { with: /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/ }
  validate :approved_scope, on: :create

  def record!
    workspace.with_lock do
      require_owner!(approved_by)
      recorded = workspace.agent_setups.find_by(request_id: request_id)
      if recorded
        unless recorded.approved_by == approved_by && recorded.slice(*APPROVAL_FIELDS) == slice(*APPROVAL_FIELDS)
          raise Conflict, "This approval form has already recorded a different setup. Open a new form."
        end
        recorded
      else
        save!
        self
      end
    end
  end

  def execute!(by:)
    with_lock do
      raise ActiveRecord::RecordNotFound unless operator_allowed?(by) && !undone_at
      return scoped_agent! if executed_at

      # The principal stays the owner. Delegation does not give the operator
      # an agent-owned machine identity or change any workspace membership.
      manager = workspace.agents.find_by(id: manager_id)
      unless manager && !manager.conversation.archived?
        errors.add(:base, "The approved manager is no longer available in this workspace.")
        raise ActiveRecord::RecordInvalid, self
      end
      created = approved_by.start_agent(name, instructions: instructions, workspace: workspace)
      created.update!(parent_id: manager.id)
      update!(agent: created, executed_at: Time.current)
      created
    end
  end

  def revoke!(by:)
    with_lock do
      require_owner!(by)
      update!(revoked_by: by, revoked_at: Time.current) unless revoked_at
    end
  end

  def undo!(by:)
    with_lock do
      require_owner!(by)
      return if undone_at
      candidate = workspace.agents.find_by(id: agent_id)
      unless reversible?(candidate)
        raise Conflict, "This setup or agent has changed. Review it in the workspace; nothing was undone."
      end

      # Archive the unused thread and detach it. Keep the agent, its approved
      # instructions and the audit, so the owner can recover it deliberately.
      candidate.update!(parent_id: nil)
      candidate.conversation.archive
      update!(undone_by: by, undone_at: Time.current)
    end
  end

  def prepare_first_turn!(message, by:)
    with_lock do
      candidate = scoped_agent
      manager = workspace.agents.find_by(id: manager_id)
      unless executed_at && !revoked_at && !undone_at && manager && manager == by && !manager.conversation.archived? &&
          candidate && candidate.parent_id == manager.id && candidate.instructions == instructions &&
          !candidate.concourse_agents.exists? && workspace.memberships.owner.exists?(user: approved_by)
        raise ActiveRecord::RecordNotFound
      end

      thread = candidate.conversation
      unless !thread.archived? && (first_turn || (thread.durable_id.blank? && !thread.submissions.exists? && !thread.messages.exists?))
        raise Conflict, "This report has already been used. A first turn cannot be added."
      end

      from = manager.name.squish
      source = { channel: HANDOFF_CHANNEL, manager_id: manager.id, setup_id: id }
      # The approval and exact recipient are checked before publishing the envelope.
      # Dispatch happens outside the lock, under this same request ID.
      Conversation::Submission.prepare(thread, message, request_id: first_turn_request_id, when_busy: "followUp",
        document_changes: false, by_person: false, source: source, author: { sender: from }) do
        Conversation.received(message, from: from, via: HANDOFF_CHANNEL, answer: nil, zone: candidate.time_zone)
      end
    end
  end

  def first_turn = scoped_agent&.conversation&.submissions&.find_by(request_id: first_turn_request_id)

  def scoped_agent = workspace.agents.find_by(id: agent_id)

  private
    def scoped_agent! = workspace.agents.find(agent_id)

    def first_turn_request_id = "manager-first-turn:#{id}:#{request_id}"

    def operator_allowed?(person)
      !revoked_at && person == operator && workspace.memberships.exists?(user: person) &&
        workspace.memberships.owner.exists?(user: approved_by)
    end

    def require_owner!(person)
      raise ActiveRecord::RecordNotFound unless workspace.memberships.owner.exists?(user: person)
    end

    def approved_scope
      errors.add(:approved_by, "must own this workspace") unless workspace.memberships.owner.exists?(user: approved_by)
      errors.add(:operator, "must be a member of this workspace") unless workspace.member?(operator)
      manager = workspace.agents.find_by(id: manager_id)
      if manager && !manager.conversation.archived?
        self.manager_name = manager.name
      else
        errors.add(:manager_id, "must be an active agent in this workspace")
      end
    end

    def reversible?(candidate)
      return false unless executed_at && candidate && candidate.name == name && candidate.instructions == instructions && candidate.parent_id == manager_id

      thread = candidate.conversation
      thread && thread.durable_id.blank? && thread.status == "idle" && !thread.messages.exists? && !thread.submissions.exists? &&
        !candidate.reports.exists? && !candidate.concourse_agents.exists? && !candidate.conversations.where.not(id: thread.id).exists?
    end
end
