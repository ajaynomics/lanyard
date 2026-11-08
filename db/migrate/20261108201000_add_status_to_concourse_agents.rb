# Where an agent stands on Concourse, now that joining can leave it waiting
# for an organization owner. Agents connected before this (pasted
# credentials) were let in, so they are admitted.
class AddStatusToConcourseAgents < ActiveRecord::Migration[8.2]
  def change
    add_column :concourse_agents, :status, :string, null: false, default: "admitted"
  end
end
