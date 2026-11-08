# Makes a new agent's Campfire bot, out of the request, so a Campfire that is
# down or has changed never stops an agent being made. Until it succeeds the
# agent's Channels page offers to make the bot.
class CampfireBotJob < ApplicationJob
  retry_on DurableAssistants::Campfire::Error, wait: :polynomially_longer, attempts: 5
  discard_on(DurableAssistants::Campfire::Changed) { |_job, changed| Rails.error.report(changed) }

  def perform(agent)
    CampfireBot.make_for(agent) unless agent.campfire_bot
  end
end
