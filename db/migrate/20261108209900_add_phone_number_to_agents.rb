class AddPhoneNumberToAgents < ActiveRecord::Migration[8.2]
  def change
    add_column :agents, :phone_number, :string
    add_index :agents, :phone_number, unique: true
  end
end
