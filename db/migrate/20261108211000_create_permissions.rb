class CreatePermissions < ActiveRecord::Migration[8.2]
  def change
    create_table :permissions do |t|
      t.references :agent, null: false, foreign_key: true
      t.string :tool_name, null: false
      t.string :recipient, null: false, default: ""
      t.references :granted_by, null: false, foreign_key: { to_table: :users }
      t.timestamps
      t.index %i[ agent_id tool_name recipient ], unique: true
    end
  end
end
