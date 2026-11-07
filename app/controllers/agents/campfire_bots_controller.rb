module Agents
  # The agent's Campfire bot, on its settings page: the key Campfire gave the
  # bot goes in; the webhook address to give Campfire comes out.
  class CampfireBotsController < ApplicationController
    before_action { @agent = Current.user.agents.find(params[:agent_id]) }

    def update
      bot = @agent.campfire_bot || @agent.build_campfire_bot
      if bot.update(params.expect(campfire_bot: [ :bot_key ]))
        redirect_to @agent, notice: "#{@agent} is a Campfire bot. Give Campfire its webhook address."
      else
        redirect_to @agent, alert: bot.errors.full_messages.to_sentence
      end
    end

    def destroy
      @agent.campfire_bot&.destroy!
      redirect_to @agent, notice: "#{@agent} is no longer a Campfire bot."
    end
  end
end
