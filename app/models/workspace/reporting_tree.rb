class Workspace::ReportingTree
  LIMIT = 3

  def self.for(workspace)
    # The workspace association may have been loaded before the write lock.
    new(workspace.agents.order(:id))
  end

  def initialize(agents)
    @agents = agents.index_by(&:id)
    @reports = @agents.values.group_by { manager(it)&.id }
  end

  def roots = reports_for(nil)
  def reports_for(agent) = @reports.fetch(agent&.id, [])
  def manager(agent) = @agents[agent.parent_id]

  def path(agent)
    chain(agent).reverse
  end

  def problem(agent, parent_id)
    return unless parent_id
    parent = @agents[parent_id]
    return "Choose a manager in this workspace." unless parent

    ancestors = chain(parent)
    return "An agent cannot report to itself or its reports." if ancestors.include?(agent) || manager(ancestors.last)
    "Reporting trees have at most three levels, including your reports." if ancestors.size + height(agent) > LIMIT
  end

  private
    def chain(agent)
      seen = []
      while agent && !seen.include?(agent)
        seen << agent
        agent = manager(agent)
      end
      seen
    end

    def height(agent, remaining = LIMIT)
      return 1 if remaining == 1 || !agent.id
      1 + (reports_for(agent).map { height(it, remaining - 1) }.max || 0)
    end
end
