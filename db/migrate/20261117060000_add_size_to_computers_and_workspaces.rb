# The size of the Sprites made for an agent (Computer::Size): a workspace's
# default and an agent's own, each part blank to leave it to the next.
# Additive: every existing workspace and computer sets none, so its Sprites
# are made at the install's default, today's size, and code from before
# ignores the columns.
class AddSizeToComputersAndWorkspaces < ActiveRecord::Migration[8.2]
  def change
    change_table :workspaces, bulk: true do |t|
      t.integer :computer_cpus
      t.integer :computer_memory_mib
      t.integer :computer_disk_mib
    end
    change_table :computers, bulk: true do |t|
      t.integer :cpus
      t.integer :memory_mib
      t.integer :disk_mib
    end
  end
end
