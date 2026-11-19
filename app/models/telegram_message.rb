# One post a Telegram bot heard in one of its chats, as it arrived
# (TelegramBot#receive). Telegram's Bot API keeps no history a bot can ask
# for, so this is the agent's only record of what a group said while it was
# not called on: in a group, only a post that mentions or answers the bot
# reaches its thread, but every post is kept here.
class TelegramMessage < ApplicationRecord
  belongs_to :telegram_bot

  # What telegram_messages searches by.
  scope :newest_first, -> { order(sent_at: :desc, id: :desc) }
  scope :in_chat, ->(chat) { where(chat_id: chat) if chat }
  scope :saying, ->(words) { where("text LIKE ? ESCAPE '\\'", "%#{sanitize_sql_like(words)}%") if words.present? }
  scope :sent_between, ->(since, before) { where(sent_at: since..before) if since || before }

  # Telegram posts an update again until it hears 200, and the job may run again: kept once.
  def self.keep(update)
    create_with(sender: update.sender, text: update.text, sent_at: update.sent_at || Time.current)
      .create_or_find_by!(chat_id: update.chat_id, message_id: update.message_id)
  end

  def listed(chat_name, time_zone)
    { id: message_id, chat: { id: chat_id, name: chat_name }, from: sender, at: sent_at.in_time_zone(time_zone).iso8601, text: text }
  end
end
