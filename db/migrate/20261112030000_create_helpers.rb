class CreateHelpers < ActiveRecord::Migration[8.2]
  def change
    create_table :helpers do |t|
      t.references :conversation, null: false, foreign_key: { on_delete: :cascade }
      t.string :call_id, null: false
      t.text :task, null: false
      t.string :state, null: false, default: "running"
      t.text :answer
      t.string :reason
      t.json :calls, null: false, default: []
      t.integer :call_count, null: false, default: 0
      t.json :usage
      t.datetime :finished_at
      t.datetime :delivered_at
      t.datetime :told_at
      t.timestamps
      t.index %i[ conversation_id call_id ], unique: true
    end
  end
end
