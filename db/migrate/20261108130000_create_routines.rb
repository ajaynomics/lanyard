class CreateRoutines < ActiveRecord::Migration[8.2]
  def change
    create_table :routines do |t|
      t.references :agent, null: false, foreign_key: true
      t.string :schedule, null: false
      t.text :prompt, null: false
      t.datetime :next_run_at
      t.datetime :last_run_at
      t.datetime :paused_at
      t.timestamps
    end
    add_index :routines, :next_run_at
  end
end
