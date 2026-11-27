class AddParentToAgents < ActiveRecord::Migration[8.2]
  def change
    add_column :agents, :parent_id, :integer
    add_index :agents, [ :workspace_id, :parent_id ]
  end
end
