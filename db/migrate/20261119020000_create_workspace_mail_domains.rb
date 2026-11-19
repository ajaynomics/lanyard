# A workspace's own mail domain (Workspace::MailDomain, #229): its agents'
# addresses, the server its mail goes out through, the saved sign-in for it
# and, optionally, the catch-all box its mail arrives in, with where the read
# of that box got to. None, as for every workspace until now: the install's.
class CreateWorkspaceMailDomains < ActiveRecord::Migration[8.2]
  def change
    create_table :workspace_mail_domains do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string :domain, null: false, index: { unique: true }
      t.string :smtp_host, null: false
      t.integer :smtp_port, null: false, default: 587
      t.string :imap_host
      t.integer :imap_port, null: false, default: 993
      t.string :vault_entry, null: false
      t.integer :inbox_validity
      t.integer :inbox_last_uid, null: false, default: 0
      t.datetime :inbox_read_at
      t.string :inbox_error
      t.timestamps
    end
  end
end
