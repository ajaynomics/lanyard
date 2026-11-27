class AddOwnInstructionApproval < ActiveRecord::Migration[8.2]
  def change
    # An old Off meant "follow ordinary approvals", not "run without approval".
    # Leave the old column in place for rolling deploys, and start all new choices unset.
    add_column :agents, :own_instruction_approval, :boolean
    add_column :workspaces, :own_instruction_approval, :boolean
  end
end
