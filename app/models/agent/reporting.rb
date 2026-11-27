module Agent::Reporting
  extend ActiveSupport::Concern

  included do
    has_many :reports, ->(agent) { where(workspace_id: agent.workspace_id) }, class_name: "Agent", foreign_key: :parent_id, inverse_of: false

    before_validation :detach_from_manager, if: :changing_workspace?
    validate :valid_reporting_line, if: :will_save_change_to_parent_id?
    before_update :promote_reports, if: :changing_workspace?
    before_destroy :promote_reports, prepend: true
    after_update_commit :broadcast_reporting_change, if: -> { saved_change_to_parent_id? || saved_change_to_workspace_id? }
    after_destroy_commit -> { workspace.broadcast_reporting_tree }
  end

  def manager
    workspace.agents.find_by(id: parent_id) if parent_id
  end

  def manager_choices
    agents = workspace.agents.order(:name, :id).to_a
    tree = Workspace::ReportingTree.new(agents)
    archived = workspace.conversations.threads.archived.pluck(:agent_id).to_set
    agents.filter_map { [ it, tree.manager(it) ] unless archived.include?(it.id) || tree.problem(self, it.id) }
  end

  def reporting_instructions = Agent::ReportingInstructions.new(self).to_s

  def reports_on_departure
    count = reports.count
    return if count.zero?

    destination = manager&.name || "the top level"
    "#{count} direct #{'report'.pluralize(count)} will move up to #{destination}, with their branches."
  end

  private
    def changing_workspace? = persisted? && will_save_change_to_workspace_id?

    def detach_from_manager = self.parent_id = nil

    def valid_reporting_line
      return if changing_workspace? || !workspace
      # SQLite starts writes with BEGIN IMMEDIATE. Materialize even if the
      # next lookup was cached, so two writers cannot validate the same tree.
      self.class.connection.materialize_transactions
      self.class.uncached do
        if persisted? && !workspace.agents.exists?(id)
          errors.add(:base, "This agent moved to another workspace. Open the picker again.")
        elsif (problem = Workspace::ReportingTree.for(workspace).problem(self, parent_id))
          errors.add(:base, problem)
        elsif parent_id && workspace.conversations.threads.archived.exists?(agent_id: parent_id)
          errors.add(:base, "That manager is archived. Choose another.")
        end
      end
    end

    def promote_reports
      old_workspace = reporting_workspace_before_move
      self.class.connection.materialize_transactions
      self.class.uncached do
        leaving = old_workspace.agents.find_by!(id: id)
        leaving.reports.update_all(parent_id: leaving.manager&.id)
      end
    end

    def reporting_workspace_before_move
      return workspace unless changing_workspace?
      Workspace.find(workspace_id_in_database) # tenancy-ok: the persisted owner of this agent
    end

    def broadcast_reporting_change
      if saved_change_to_workspace_id?
        Workspace.find(workspace_id_before_last_save).broadcast_reporting_tree # tenancy-ok: the previous owner of this agent
      end
      workspace.broadcast_reporting_tree
    end
end
