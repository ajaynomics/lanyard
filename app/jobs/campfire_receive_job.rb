class CampfireReceiveJob < ApplicationJob
  # The payload is a room's message, words and all, so it stays out of the log.
  self.log_arguments = false
  retry_on DurableAssistants::PiDurable::Client::Error, wait: :polynomially_longer, attempts: 5

  def perform(campfire_bot, payload) = campfire_bot.receive(payload)
end
