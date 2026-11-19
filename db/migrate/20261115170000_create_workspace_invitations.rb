# The owner of a shared workspace invites people by email
# (docs/design/workspaces.md). An invitation admits its email until it is
# accepted at sign-in, becoming a membership, or cancelled. A new table only.
class CreateWorkspaceInvitations < ActiveRecord::Migration[8.2]
  def change
    create_table :workspace_invitations do |t|
      t.references :workspace, null: false, foreign_key: true
      t.references :inviter, null: false, foreign_key: { to_table: :users }
      t.string :email, null: false
      t.timestamps
    end
    add_index :workspace_invitations, %i[ workspace_id email ], unique: true
    add_index :workspace_invitations, :email
  end
end
