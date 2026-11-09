class AddCaldavAccountToAgents < ActiveRecord::Migration[8.2]
  def change
    add_column :agents, :caldav_username, :string
    add_column :agents, :caldav_password, :text
  end
end
