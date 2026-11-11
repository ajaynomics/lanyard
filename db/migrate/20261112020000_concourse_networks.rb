# An agent may hold an identity in several Concourse organizations (networks),
# one each. Each task is tagged with the identity it came or went on; a blank
# tag, every task from before this, means the agent's first identity. The tag
# has no foreign key on purpose: when an identity is disconnected its tasks
# keep its id, so they never move to another network (ConcourseAgent#disconnect).
# Going back refuses while any agent holds two identities, rather than
# choosing one to delete.
class ConcourseNetworks < ActiveRecord::Migration[8.2]
  def change
    remove_index :concourse_agents, :agent_id, unique: true
    add_index :concourse_agents, %i[ agent_id organization ], unique: true
    add_reference :peer_tasks, :concourse_agent, null: true, index: true

    reversible do |direction|
      direction.down do
        if select_value("SELECT 1 FROM concourse_agents GROUP BY agent_id HAVING COUNT(*) > 1 LIMIT 1")
          raise ActiveRecord::IrreversibleMigration, "An agent is on more than one Concourse network. Disconnect all but one of each agent's networks first."
        end
      end
    end
  end
end
