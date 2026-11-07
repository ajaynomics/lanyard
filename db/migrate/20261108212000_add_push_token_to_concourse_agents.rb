class AddPushTokenToConcourseAgents < ActiveRecord::Migration[8.2]
  def change
    add_column :concourse_agents, :push_token, :text
  end
end
