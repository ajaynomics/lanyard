# Whether an agent's cards reach its people as priority notifications (#82):
# on for every agent, as each sounded before, until someone lowers it.
class AddPriorityNotificationsToAgents < ActiveRecord::Migration[8.2]
  def change
    add_column :agents, :priority_notifications, :boolean, default: true, null: false
  end
end
