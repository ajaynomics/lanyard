# When Campfire vouched for a bot's key (CampfireBot#confirmed_campfire_id):
# the administrator acts on a bot by its number only after that. Existing bots
# start unvouched and are checked the first time the administrator acts.
class AddConfirmedAtToCampfireBots < ActiveRecord::Migration[8.2]
  def change
    add_column :campfire_bots, :confirmed_at, :datetime
  end
end
