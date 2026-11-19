# Whose model account a workspace's calls are billed to (docs/billing.md):
# empty, the install's, as every call was before; itself; or another
# workspace, chosen by someone who owns both. Existing workspaces stay empty,
# so nothing about who pays changes until someone chooses.
#
# The foreign key makes SQLite rebuild workspaces, dropping the old table.
# Rails turns foreign keys off for that, but SQLite ignores the switch inside
# a transaction, so in the migration's own transaction the drop emptied every
# table whose key cascades from workspaces. Outside one the switch holds, and
# the rebuild still runs in a transaction of its own; the schema is the same.
class AddPayerToWorkspaces < ActiveRecord::Migration[8.2]
  disable_ddl_transaction!

  def change
    add_reference :workspaces, :payer, foreign_key: { to_table: :workspaces, on_delete: :nullify }
  end
end
