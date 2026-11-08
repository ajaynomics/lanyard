class HoldSpinningCampfireRooms < ActiveRecord::Migration[8.2]
  def change
    add_column :campfire_rooms, :relayed_at, :json, default: [], null: false
    add_column :campfire_rooms, :held_at, :datetime
  end
end
