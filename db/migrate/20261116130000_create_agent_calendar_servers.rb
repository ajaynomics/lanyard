# Where an agent's own calendar lives when it is not the install's CalDAV
# server (#77): its account's calendar home and the name of the vault entry
# holding the account's sign-in. A new table, so an old release running
# during a rolling deploy neither reads nor writes it, and every existing
# agent keeps the install's account.
class CreateAgentCalendarServers < ActiveRecord::Migration[8.2]
  def change
    create_table :agent_calendar_servers do |t|
      t.references :agent, null: false, foreign_key: true, index: { unique: true }
      t.string :url, null: false
      t.string :vault_entry, null: false
      t.timestamps
    end
  end
end
