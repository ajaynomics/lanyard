# A workspace may be shared (docs/design/workspaces.md): many members, exactly
# one owner. Every membership so far is a person in their own workspace, so it
# becomes that workspace's owner, and every workspace so far is a personal one.
# A shared workspace has a name; a personal one shows its person's. Only
# columns are added, with defaults the release before this one writes safely.
class ShareWorkspaces < ActiveRecord::Migration[8.2]
  def up
    add_column :workspace_memberships, :role, :string, null: false, default: "owner"
    add_index :workspace_memberships, :workspace_id, unique: true, where: "role = 'owner'", name: "index_workspace_memberships_one_owner"

    add_column :workspaces, :name, :string
    add_column :workspaces, :personal, :boolean, null: false, default: false
    execute "UPDATE workspaces SET personal = TRUE"
  end

  def down
    remove_column :workspaces, :personal
    remove_column :workspaces, :name
    remove_index :workspace_memberships, name: "index_workspace_memberships_one_owner"
    remove_column :workspace_memberships, :role
  end
end
