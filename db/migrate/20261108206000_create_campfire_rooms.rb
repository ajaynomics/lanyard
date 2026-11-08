class CreateCampfireRooms < ActiveRecord::Migration[8.2]
  def change
    create_table :campfire_rooms do |t|
      t.references :user, null: false, foreign_key: true
      t.integer :room_id, null: false
      t.integer :relays_in_a_row, null: false, default: 0
      t.timestamps
      t.index %i[ user_id room_id ], unique: true
    end
  end
end
