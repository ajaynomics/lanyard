class CampfireReceiveJob < ApplicationJob
  retry_on DurableAssistants::PiDurable::Client::Error, wait: :polynomially_longer, attempts: 5

  def perform(campfire_bot, payload) = campfire_bot.receive(payload)
end
