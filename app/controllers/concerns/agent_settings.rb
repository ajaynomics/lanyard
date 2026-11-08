# What an agent's settings sections share: the agent, reached through the
# person, and the settings layout.
module AgentSettings
  extend ActiveSupport::Concern

  included do
    layout "settings"
    before_action { @agent = Current.user.agents.find(params[:agent_id]) }
  end
end
