class PinEventOnlyCalendarCollections < ActiveRecord::Migration[8.2]
  def change
    add_column :agent_calendar_servers, :pinned_collections, :json
  end
end
