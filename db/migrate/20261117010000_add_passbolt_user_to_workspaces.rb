# A workspace's own Passbolt user (Workspace::VaultUser), encrypted, which its
# agents read the vault as when they have none of their own. Two empty
# columns: every existing workspace stays on the install's user, and code
# from before neither reads nor writes them.
class AddPassboltUserToWorkspaces < ActiveRecord::Migration[8.2]
  def change
    add_column :workspaces, :passbolt_private_key, :text
    add_column :workspaces, :passbolt_passphrase, :text
  end
end
