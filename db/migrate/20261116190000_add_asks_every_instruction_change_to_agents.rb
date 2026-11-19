class AddAsksEveryInstructionChangeToAgents < ActiveRecord::Migration[8.2]
  def change
    add_column :agents, :asks_every_instruction_change, :boolean, default: true, null: false
  end
end
