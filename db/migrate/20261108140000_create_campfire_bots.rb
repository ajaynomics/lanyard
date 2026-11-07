class CreateCampfireBots < ActiveRecord::Migration[8.2]
  def change
    create_table :campfire_bots do |t|
      t.references :agent, null: false, foreign_key: true, index: { unique: true }
      t.string :bot_key, null: false
      t.string :token, null: false, index: { unique: true }
      t.json :rooms, null: false, default: {}
      t.timestamps
    end
  end
end
