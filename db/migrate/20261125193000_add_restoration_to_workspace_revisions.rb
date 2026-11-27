class AddRestorationToWorkspaceRevisions < ActiveRecord::Migration[8.2]
  def change
    add_reference :workspace_revisions, :restored_by, foreign_key: { to_table: :users, on_delete: :nullify }
    add_reference :workspace_revisions, :restored_from, foreign_key: { to_table: :workspace_revisions, on_delete: :nullify }
  end
end
