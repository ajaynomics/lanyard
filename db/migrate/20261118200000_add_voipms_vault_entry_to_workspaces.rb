# The vault entry that holds a workspace's own voip.ms API username and
# password, by name, as its Campfire's administrator is named: read from the
# vault each time a text is sent or looked up, never kept here. Empty for
# every workspace already there, whose agents text through the install's.
class AddVoipmsVaultEntryToWorkspaces < ActiveRecord::Migration[8.2]
  def change
    add_column :workspaces, :voipms_vault_entry, :string
  end
end
