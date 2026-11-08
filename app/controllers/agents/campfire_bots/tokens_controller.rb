module Agents
  module CampfireBots
    # A new webhook address: the old one stops working at once.
    class TokensController < ApplicationController
      def create
        agent = Current.user.agents.find(params[:agent_id])
        (agent.campfire_bot or raise ActiveRecord::RecordNotFound).regenerate_token
        redirect_to agent_channels_path(agent), notice: "New webhook address. Give it to Campfire; the old one no longer works."
      end
    end
  end
end
