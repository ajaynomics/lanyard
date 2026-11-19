# An agent's Telegram bot (TelegramBot, docs/telegram.md): the name of the
# vault entry holding its token, never the token; the secret Telegram sends
# with each update; and the chats it has heard from. A new table, so code from
# before, running during a rolling deploy or after a rollback, neither reads
# nor writes it, and every existing agent is as it was; its key cascades, so
# that code can still delete the agent it belongs to.
class CreateTelegramBots < ActiveRecord::Migration[8.2]
  def change
    create_table :telegram_bots do |t|
      t.references :agent, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string :vault_entry, null: false
      t.string :username
      t.string :webhook_secret, null: false
      t.json :chats, null: false, default: {}
      t.timestamps
    end
  end
end
