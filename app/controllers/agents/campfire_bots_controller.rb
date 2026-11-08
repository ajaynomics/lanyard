module Agents
  # The agent's Campfire bot, on its settings page: made in Campfire when the
  # install can sign in as its administrator; otherwise the key Campfire gave
  # the bot goes in and the webhook address to give Campfire comes out.
  class CampfireBotsController < ApplicationController
    before_action { @agent = Current.user.agents.find(params[:agent_id]) }

    def create
      CampfireBot.make_for(@agent) unless @agent.campfire_bot
      redirect_to agent_channels_path(@agent), notice: "#{@agent} is a Campfire bot, in every open room."
    rescue DurableAssistants::Campfire::Error => error
      redirect_to agent_channels_path(@agent), alert: error.message
    end

    def update
      bot = @agent.campfire_bot || @agent.build_campfire_bot
      if bot.update(params.expect(campfire_bot: [ :bot_key ]))
        redirect_to agent_channels_path(@agent), notice: "#{@agent} is a Campfire bot. Give Campfire its webhook address."
      else
        redirect_to agent_channels_path(@agent), alert: bot.errors.full_messages.to_sentence
      end
    end

    def destroy
      @agent.campfire_bot&.destroy!
      redirect_to agent_channels_path(@agent), notice: "#{@agent} is no longer a Campfire bot."
    end
  end
end
