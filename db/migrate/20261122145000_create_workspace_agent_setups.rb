class CreateWorkspaceAgentSetups < ActiveRecord::Migration[8.2]
  def change
    create_table :workspace_agent_setups do |t|
      t.references :workspace, null: false, foreign_key: true
      t.string :request_id, null: false
      t.index %i[ workspace_id request_id ], unique: true
      t.references :approved_by, null: false, foreign_key: { to_table: :users }
      t.references :operator, null: false, foreign_key: { to_table: :users }
      t.references :agent, foreign_key: { on_delete: :nullify }, index: { unique: true }
      t.bigint :manager_id, null: false
      t.string :manager_name, null: false
      t.string :name, null: false
      t.text :instructions, null: false
      t.text :authorization, null: false
      t.datetime :executed_at
      t.datetime :revoked_at
      t.references :revoked_by, foreign_key: { to_table: :users }
      t.datetime :undone_at
      t.references :undone_by, foreign_key: { to_table: :users }
      t.timestamps
    end
  end
end
