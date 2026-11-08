class AddPassboltKeyToAgents < ActiveRecord::Migration[8.2]
  def change
    add_column :agents, :passbolt_private_key, :text
    add_column :agents, :passbolt_passphrase, :text
  end
end
