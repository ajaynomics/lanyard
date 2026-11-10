# Files the sidecar read from an agent's computer for a call (Upload), held
# here until the call uses them or the sweep clears them.
class CreateUploads < ActiveRecord::Migration[8.2]
  def change
    create_table :uploads do |t|
      t.references :conversation, null: false, foreign_key: true
      t.string :task_id, null: false
      t.string :call_id, null: false
      t.string :path, null: false
      t.string :sha256, null: false
      t.timestamps
      t.index %i[ conversation_id task_id call_id path ], unique: true
    end
  end
end
