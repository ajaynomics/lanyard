# The vault entry that holds a connector's own OAuth app (a Clio connector's
# client ID and secret), by name, as an agent's mail account names its entry:
# the secret is read from the vault each time it is needed and never kept
# here. Empty for every connector already there.
class AddVaultEntryToMcpServers < ActiveRecord::Migration[8.2]
  def change
    add_column :mcp_servers, :vault_entry, :string
  end
end
