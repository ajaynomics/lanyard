class RemoveRelaysInARowFromCampfireRooms < ActiveRecord::Migration[8.2]
  def change
    remove_column :campfire_rooms, :relays_in_a_row, :integer, default: 0, null: false
  end
end
