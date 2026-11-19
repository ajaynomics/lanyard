class CreateWorkflows < ActiveRecord::Migration[8.2]
  def change
    create_table :workflows do |t|
      t.references :conversation, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.string :kind, null: false
      t.json :steps, null: false, default: []
      t.text :context
      t.timestamps
    end

    create_table :workflow_runs do |t|
      t.references :workflow, null: false, foreign_key: { on_delete: :cascade }
      t.string :call_id, null: false
      t.string :state, null: false, default: "running"
      t.datetime :finished_at
      t.datetime :delivered_at
      t.datetime :told_at
      t.timestamps
      t.index %i[ workflow_id call_id ], unique: true
      t.index :state
    end

    create_table :workflow_steps do |t|
      t.references :run, null: false, foreign_key: { to_table: :workflow_runs, on_delete: :cascade }
      t.integer :position, null: false
      t.string :call_id, null: false, index: { unique: true }
      t.text :task, null: false
      t.text :context
      t.string :state, null: false, default: "pending"
      t.text :answer
      t.string :reason
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
      t.index %i[ run_id position ], unique: true
    end
  end
end
