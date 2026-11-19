# An "Always" given by someone since removed from, or who left, the agent's
# workspace no longer stands: removal now takes it (Workspace::Membership),
# and this takes those given before it did. Only rows go, so code from before,
# running during a rolling deploy, reads the permissions that remain as ever.
class RevokePermissionsOfPeopleWhoLeft < ActiveRecord::Migration[8.2]
  def up
    execute <<~SQL
      DELETE FROM permissions WHERE NOT EXISTS (
        SELECT 1 FROM agents JOIN workspace_memberships ON workspace_memberships.workspace_id = agents.workspace_id
        WHERE agents.id = permissions.agent_id AND workspace_memberships.user_id = permissions.granted_by_id
      )
    SQL
  end

  def down
  end
end
