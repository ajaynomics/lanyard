class AddActivatedToolsToConversations < ActiveRecord::Migration[8.2]
  def change
    add_column :conversations, :activated_tools, :json, default: [], null: false
  end
end
