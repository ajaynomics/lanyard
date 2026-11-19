# What a Telegram bot heard (TelegramMessage, docs/telegram.md): each post in
# its chats, kept as it arrived, since the Bot API keeps no history to ask for
# later. A new table, so code from before, running during a rolling deploy or
# after a rollback, neither reads nor writes it, and every existing bot is as
# it was; its key cascades, so that code can still delete the bot or agent.
class CreateTelegramMessages < ActiveRecord::Migration[8.2]
  def change
    create_table :telegram_messages do |t|
      t.references :telegram_bot, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.bigint :chat_id, null: false
      t.bigint :message_id, null: false
      t.string :sender, null: false
      t.text :text, null: false
      t.datetime :sent_at, null: false
      t.datetime :created_at, null: false
      # Telegram posts an update again until it hears 200: kept once.
      t.index [ :telegram_bot_id, :chat_id, :message_id ], unique: true
      t.index [ :telegram_bot_id, :chat_id, :sent_at ]
    end
  end
end
