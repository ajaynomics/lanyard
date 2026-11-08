module Agents
  module CampfireBots
    # A new webhook address: the old one stops working at once.
    class TokensController < ApplicationController
      def create
        agent = Current.user.agents.find(params[:agent_id])
        if (agent.campfire_bot or raise ActiveRecord::RecordNotFound).renew_webhook
          redirect_to agent_channels_path(agent), notice: "New webhook address, and Campfire has it."
        else
          redirect_to agent_channels_path(agent), notice: "New webhook address. Give it to Campfire; the old one no longer works."
        end
      rescue DurableAssistants::Campfire::Error => error
        redirect_to agent_channels_path(agent), alert: "New webhook address, but Campfire wasn't told: #{error.message}"
      end
    end
  end
end
