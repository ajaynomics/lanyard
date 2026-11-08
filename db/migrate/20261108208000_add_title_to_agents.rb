class AddTitleToAgents < ActiveRecord::Migration[8.2]
  def change
    add_column :agents, :title, :string
  end
end
