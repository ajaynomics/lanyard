# One message handed to an outside provider (Dispatch), written before the
# provider is asked, so a send whose answer never came is known to have been
# tried, and is checked rather than sent again. A new table, so code from
# before, running during a rolling deploy, neither reads nor writes it: that
# code sends as before. It goes with its call in the database itself, so code
# from before deletes calls and conversations without knowing it is there.
class CreateDispatches < ActiveRecord::Migration[8.2]
  def change
    create_table :dispatches do |t|
      t.references :invocation, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string :key, null: false, index: { unique: true }
      t.string :tool_name, null: false
      t.string :state, null: false, default: "pending"
      t.string :sender, null: false
      t.string :fingerprint, null: false, index: true
      t.string :provider_id
      t.integer :checks, null: false, default: 0
      t.datetime :settled_at
      # A person only recorded: one who leaves takes nothing with them.
      t.references :closed_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.timestamps
    end
  end
end
