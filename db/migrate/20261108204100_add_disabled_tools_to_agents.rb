# Tools the person turned off for this agent only, by the names the agent
# declares them under (mcp__wiki__search, send_email).
class AddDisabledToolsToAgents < ActiveRecord::Migration[8.2]
  def change
    add_column :agents, :disabled_tools, :json, default: [], null: false
  end
end
