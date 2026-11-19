# Telegram posts here each update for an agent's bot (TelegramBot), with the
# secret the app gave it in a header, compared in constant time: the secret
# admits it, not the path, an address or anything else. It answers at once,
# and the agent hears it from a job. A wrong secret and an unknown bot look
# alike: 404.
class TelegramWebhooksController < ActionController::API
  SECRET = "X-Telegram-Bot-Api-Secret-Token".freeze

  wrap_parameters false
  # Telegram posts from a few addresses for every bot, so an address gets more room than a bot.
  rate_limit to: 600, within: 1.minute, name: "address"
  rate_limit to: 60, within: 1.minute, by: -> { params[:id].to_s }, name: "bot"

  def create
    bot = TelegramBot.find_by(id: params[:id].to_s) # tenancy-ok: the bot's own secret, checked next, is what admits the post
    return head :not_found unless bot&.secret?(request.headers[SECRET]) && bot.usable?
    TelegramReceiveJob.perform_later(bot, request.request_parameters.slice("update_id", "message").to_h)
    head :ok
  end
end
