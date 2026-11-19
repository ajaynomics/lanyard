# A connector that stopped being core for an agent without anyone choosing it:
# a refresh brought it more tools than fit beside the agent's others, so it
# is looked up instead (McpServer#refresh). Kept to say so on the agent's
# Tools, and to tell the agent how to reach it (Agent#lookup_note). The name
# stays when the connector goes.
class Agent::ConnectorMove < ApplicationRecord
  self.table_name = "connector_moves"

  belongs_to :agent
  belongs_to :mcp_server, optional: true

  validates :connector_name, :reason, presence: true

  scope :newest_first, -> { order(created_at: :desc, id: :desc) }

  # Still lookup for its agent, so what the agent was told still holds.
  def in_effect?(core_ids = agent.core_server_ids) = mcp_server.present? && mcp_server.enabled? && !agent.core?(mcp_server, core_ids)
end
