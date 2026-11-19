# An agent's own Claude route (docs/agent.md, "Claude routes"): empty is the
# install's order, as every agent ran before, so nothing changes until someone
# chooses one.
class AddClaudeRouteToAgents < ActiveRecord::Migration[8.2]
  def change
    add_column :agents, :claude_route, :string
  end
end
