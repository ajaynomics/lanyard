class AddRestorationToAgentRevisions < ActiveRecord::Migration[8.2]
  def change
    add_reference :agent_revisions, :restored_by, foreign_key: { to_table: :users, on_delete: :nullify }
    add_reference :agent_revisions, :restored_from, foreign_key: { to_table: :agent_revisions, on_delete: :nullify }
  end
end
