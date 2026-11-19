class TelegramReceiveJob < ApplicationJob
  # The update is a chat's message, words and all, so it stays out of the log.
  self.log_arguments = false
  retry_on DurableAssistants::PiDurable::Client::Error, Conversation::Submission::Refused, wait: :polynomially_longer, attempts: 5

  def perform(telegram_bot, update) = telegram_bot.receive(update)
end
