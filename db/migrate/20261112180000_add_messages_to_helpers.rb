class AddMessagesToHelpers < ActiveRecord::Migration[8.2]
  def change
    add_column :helpers, :messages, :json, default: [], null: false
  end
end
