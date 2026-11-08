class AddAskersToCampfireBots < ActiveRecord::Migration[8.2]
  def change
    add_column :campfire_bots, :askers, :json, default: {}, null: false
  end
end
