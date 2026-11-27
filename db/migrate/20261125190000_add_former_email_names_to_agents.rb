# Addresses an agent has left (Agent). Safe across a rolling deploy: code from
# before ignores it and can't change an address, so every row starts with none.
class AddFormerEmailNamesToAgents < ActiveRecord::Migration[8.2]
  def change
    add_column :agents, :former_email_names, :json, default: [], null: false
  end
end
