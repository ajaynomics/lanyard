# What model calls used, recorded as each run or helper ends, against the
# workspace and agent that made them and the workspace they were billed to
# (docs/billing.md). A new table only. Rows outlive their agent, thread and
# helper, which are only recorded; the agent's name is kept beside.
class CreateModelUsages < ActiveRecord::Migration[8.2]
  def change
    create_table :model_usages do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :agent, foreign_key: { on_delete: :nullify }
      t.string :agent_name, null: false
      t.references :conversation, foreign_key: { on_delete: :nullify }
      t.references :helper, foreign_key: { on_delete: :nullify }
      t.references :payer, foreign_key: { to_table: :workspaces, on_delete: :nullify }
      t.string :model
      t.string :tool
      t.integer :input, null: false, default: 0
      t.integer :output, null: false, default: 0
      t.integer :cache_read, null: false, default: 0
      t.integer :cache_write, null: false, default: 0
      t.integer :total_tokens, null: false, default: 0
      t.decimal :cost, precision: 14, scale: 6
      t.datetime :created_at, null: false
    end
    add_index :model_usages, %i[ workspace_id created_at ]
  end
end
