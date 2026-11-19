# One of its workspace's connectors whose tools this agent carries in every
# message: core for it. Any other connector there is lookup for it, found
# with find_tools or a code mode script's searchTools() (docs/connectors.md).
# Each agent decides for itself, so one near the limit never moves a connector
# for another. A conversation's own connector belongs to one agent already and
# says so itself (McpServer#loaded).
class Agent::CoreConnector < ApplicationRecord
  self.table_name = "core_connectors"

  belongs_to :agent
  belongs_to :mcp_server

  validates :mcp_server_id, uniqueness: { scope: :agent_id }
  validate :the_persons_own
  validate :fits, on: :create, if: -> { agent && mcp_server }

  private
    def the_persons_own
      return if agent && mcp_server && mcp_server.workspace_id == agent.workspace_id && mcp_server.conversation_id.nil?
      errors.add(:mcp_server, "is not one of the workspace's connectors")
    end

    # Against this agent's limit alone, never another's.
    def fits
      count = agent.tool_count_with_core(mcp_server)
      return if count <= Agent::TOOL_LIMIT
      errors.add(:base, "#{mcp_server.name} offers #{mcp_server.tool_classes.size} tools; core, it would give #{agent} #{count}, " \
        "and an agent can have #{Agent::TOOL_LIMIT}. Keep it looked up, or switch some tools off")
    end
end
