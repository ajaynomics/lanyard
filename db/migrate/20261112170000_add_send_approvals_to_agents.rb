class AddSendApprovalsToAgents < ActiveRecord::Migration[8.2]
  def change
    add_column :agents, :asks_every_email, :boolean, default: false, null: false
    add_column :agents, :asks_every_text, :boolean, default: false, null: false
    add_column :agents, :asks_every_imessage, :boolean, default: false, null: false
    add_column :agents, :asks_every_concourse_send, :boolean, default: false, null: false
  end
end
