# An invitation is emailed only once an admin of the install says yes: the
# inviter, being one, or another in Settings. Those made before were emailed
# at once, or shared by hand, so they count as approved when made, by nobody
# recorded. Added columns only: code from before, running during a rolling
# deploy, neither reads nor writes them.
class AddApprovalToWorkspaceInvitations < ActiveRecord::Migration[8.2]
  def up
    add_column :workspace_invitations, :approved_at, :datetime
    add_reference :workspace_invitations, :approver, foreign_key: { to_table: :users, on_delete: :nullify }
    execute "UPDATE workspace_invitations SET approved_at = created_at"
  end

  def down
    remove_reference :workspace_invitations, :approver, foreign_key: { to_table: :users }
    remove_column :workspace_invitations, :approved_at
  end
end
