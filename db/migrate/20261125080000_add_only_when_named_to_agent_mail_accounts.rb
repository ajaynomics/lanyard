# Accounts an agent sends from only when a message names them (#630,
# docs/email.md). Safe across a rolling deploy: the column defaults to false,
# so every existing row, and one saved by code from before, stays its
# default; the sending index leaves named-only rows out, so the database
# still keeps one default per agent. Code from before would take a named-only
# row for its default, so none is added until this code runs everywhere.
class AddOnlyWhenNamedToAgentMailAccounts < ActiveRecord::Migration[8.2]
  def change
    add_column :agent_mail_accounts, :only_when_named, :boolean, default: false, null: false
    remove_index :agent_mail_accounts, :agent_id, unique: true, where: "NOT read_only", name: "index_agent_mail_accounts_sending"
    add_index :agent_mail_accounts, :agent_id, unique: true, where: "NOT read_only AND NOT only_when_named", name: "index_agent_mail_accounts_sending"
  end
end
