# Many mailboxes and calendar servers per agent: its own, which it sends and
# writes through, and others it only reads, such as a colleague's whose work
# it took over (docs/email.md, "Read-only mailboxes"; docs/calendar.md).
#
# Safe across a rolling deploy, in one migration:
#
# - read_only defaults to false, so every existing row, and one saved by code
#   from before while both run, stays the agent's sending account (or its own
#   calendar server).
# - The unique index on agent_id becomes a partial one, unique only among rows
#   that are not read only. Code from before still finds the one row it knows
#   (it never makes a read-only one), and its own uniqueness validation still
#   keeps it to one; the database now keeps the sending one to one per agent.
#   A unique (agent_id, address) or (agent_id, url) index keeps the lookups by
#   agent fast and refuses the same mailbox twice.
# - smtp_host may be null: a read-only mailbox has no server to send through.
#   Code from before always sets it.
# - Where each folder of a read-only mailbox has been read to is a new table,
#   which code from before neither reads nor writes. The sending account keeps
#   its inbox_* columns.
class AddReadOnlyToAgentMailAccounts < ActiveRecord::Migration[8.2]
  def change
    add_column :agent_mail_accounts, :read_only, :boolean, default: false, null: false
    add_column :agent_mail_accounts, :folder_names, :string
    change_column_null :agent_mail_accounts, :smtp_host, true
    add_index :agent_mail_accounts, %i[ agent_id address ], unique: true
    remove_index :agent_mail_accounts, :agent_id, unique: true
    add_index :agent_mail_accounts, :agent_id, unique: true, where: "NOT read_only", name: "index_agent_mail_accounts_sending"

    add_column :agent_calendar_servers, :read_only, :boolean, default: false, null: false
    add_index :agent_calendar_servers, %i[ agent_id url ], unique: true
    remove_index :agent_calendar_servers, :agent_id, unique: true
    add_index :agent_calendar_servers, :agent_id, unique: true, where: "NOT read_only", name: "index_agent_calendar_servers_writable"

    create_table :agent_mail_account_folders do |t|
      t.references :mail_account, null: false, foreign_key: { to_table: :agent_mail_accounts, on_delete: :cascade }, index: false
      t.string :name, null: false
      t.integer :validity
      t.integer :last_uid, null: false, default: 0
      t.datetime :read_at
      t.timestamps
      t.index %i[ mail_account_id name ], unique: true
    end
  end
end
