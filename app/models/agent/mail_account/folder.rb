# Where one folder of a mailbox the agent only reads has been read to
# (Agent::MailAccount::Inbox): the folder's UIDVALIDITY, the last UID taken
# and the last good read. Its first read starts at its newest message.
class Agent::MailAccount::Folder < ApplicationRecord
  belongs_to :mail_account, class_name: "Agent::MailAccount"

  def place = [ validity, last_uid, read_at ]
  def place!(validity, uid, read_at = nil) = update_columns({ validity: validity, last_uid: uid, read_at: read_at }.compact)
end
