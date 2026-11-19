# Where an agent's own inbox has been read to (#77): the box's UIDVALIDITY and
# the last UID taken, the last good read and, when the last read failed, why.
# Additive: an existing account, or one saved by code from before during a
# rolling deploy, has never been read, so its first read starts at the box's
# newest message.
class AddInboxToAgentMailAccounts < ActiveRecord::Migration[8.2]
  def change
    add_column :agent_mail_accounts, :inbox_validity, :integer
    add_column :agent_mail_accounts, :inbox_last_uid, :integer, null: false, default: 0
    add_column :agent_mail_accounts, :inbox_read_at, :datetime
    add_column :agent_mail_accounts, :inbox_error, :string
  end
end
