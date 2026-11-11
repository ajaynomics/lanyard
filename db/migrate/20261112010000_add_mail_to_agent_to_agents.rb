# The agent that now takes an agent's mail, when one has replaced it (Agent,
# AgentsMailbox, docs/email.md). Empty for every agent; deleting the agent it
# names empties it again, so mail goes back to the old agent.
class AddMailToAgentToAgents < ActiveRecord::Migration[8.2]
  def change
    add_reference :agents, :mail_to_agent, null: true, foreign_key: { to_table: :agents, on_delete: :nullify }
  end
end
