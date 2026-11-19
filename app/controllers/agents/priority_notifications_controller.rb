module Agents
  # Whether the agent's cards reach its people as priority notifications, on
  # its General page (#82). Only the owner of its workspace changes it: it
  # decides how every member is interrupted. Another member sees it, read-only.
  class PriorityNotificationsController < ApplicationController
    include AgentSettings

    before_action { head :not_found unless @agent.owned_by?(Current.user) }

    def update
      @agent.update!(params.expect(agent: %i[ priority_notifications ]))
      saved @agent
    end
  end
end
