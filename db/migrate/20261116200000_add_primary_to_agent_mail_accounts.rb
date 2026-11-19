# An owner may make an agent's own mail account its only address
# (docs/email.md, "Its only address"): it sends from nothing else, its
# address here is never said to it, and mail to that address is turned away.
#
# Safe across a rolling deploy: primary defaults to false, so every existing
# account, and one saved by code from before while both run, leaves the agent
# using its address here as before. Code from before neither reads nor writes
# it; an account made primary is honoured once the new code is running.
class AddPrimaryToAgentMailAccounts < ActiveRecord::Migration[8.2]
  def change
    add_column :agent_mail_accounts, :primary, :boolean, default: false, null: false
  end
end
