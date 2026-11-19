# An agent's own mail account (#77): the address it sends from, the server it
# sends through, and the name of the vault entry holding the mailbox's sign-in.
# A new table, so an old release running during a rolling deploy neither reads
# nor writes it, and every existing agent keeps sending as before. The IMAP
# columns wait for the agent's own inbox.
class CreateAgentMailAccounts < ActiveRecord::Migration[8.2]
  def change
    create_table :agent_mail_accounts do |t|
      t.references :agent, null: false, foreign_key: true, index: { unique: true }
      t.string :address, null: false
      t.string :display_name
      t.string :smtp_host, null: false
      t.integer :smtp_port, null: false, default: 587
      t.string :imap_host
      t.integer :imap_port, null: false, default: 993
      t.string :vault_entry, null: false
      t.string :forced_bcc
      t.timestamps
    end
  end
end
