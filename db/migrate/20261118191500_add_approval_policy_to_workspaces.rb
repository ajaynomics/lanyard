# Each workspace's own approval policy (#226, Workspace::ApprovalPolicy). None
# at first: every workspace keeps the install's (APP__APPROVE_EVERYTHING,
# APP__APPROVALS), so nothing asks more or less on deploy. Only added, so the
# release before runs on it unchanged.
class AddApprovalPolicyToWorkspaces < ActiveRecord::Migration[8.2]
  def change
    add_column :workspaces, :approval_policy, :string
  end
end
