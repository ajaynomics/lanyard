module Bots
  # The bot's Concourse identity, on its settings page: the organization,
  # handle, client id and secret the Concourse operator issued. Saving tests
  # the connection; saving again with the secret left blank keeps it and tests
  # again.
  class ConcourseAgentsController < ApplicationController
    def update
      bot = Current.user.bots.find(params[:bot_id])
      agent = bot.concourse_agent || bot.build_concourse_agent
      attributes = params.expect(concourse_agent: %i[ organization handle client_id client_secret ])
      attributes.delete(:client_secret) if attributes[:client_secret].blank? && agent.persisted?
      if agent.update(attributes)
        if agent.check
          redirect_to bot, notice: "Connected to Concourse as #{agent}."
        else
          redirect_to bot, alert: "Saved, but the connection failed: #{agent.check_error}"
        end
      else
        redirect_to bot, alert: agent.errors.full_messages.to_sentence
      end
    end

    def destroy
      bot = Current.user.bots.find(params[:bot_id])
      bot.concourse_agent&.destroy!
      redirect_to bot, notice: "#{bot} is no longer on Concourse."
    end
  end
end
