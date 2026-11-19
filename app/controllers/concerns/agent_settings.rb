# What an agent's settings sections share: the agent, reached through the
# workspace (opened from a link, through any of the person's), and the settings layout.
module AgentSettings
  extend ActiveSupport::Concern

  included do
    layout "settings"
    before_action { @agent = find_in_workspace(:agents, params[:agent_id]) }
  end
end
