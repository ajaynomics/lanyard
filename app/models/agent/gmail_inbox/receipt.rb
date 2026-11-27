# A Gmail ID is local to its mailbox and the receiving agent. Keep it even
# after moving the history cursor: Google can report that message again.
class Agent::GmailInbox::Receipt < ApplicationRecord
  self.table_name = "agent_gmail_inbox_receipts"

  belongs_to :gmail_inbox, class_name: "Agent::GmailInbox"
end
