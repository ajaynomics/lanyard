# A workspace's own Passbolt server (Workspace::VaultUser), beside its user.
# One empty column: every existing workspace stays on the install's server,
# and code from before neither reads nor writes it.
class AddPassboltUrlToWorkspaces < ActiveRecord::Migration[8.2]
  def change
    add_column :workspaces, :passbolt_url, :string
  end
end
