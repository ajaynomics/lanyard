# An operator holds an agent's computer while rebuilding its Sprite
# (Computer#hold!), so nothing the agent does makes a fresh one meanwhile.
# Additive: every existing computer is not held, and code from before ignores
# the column.
class AddHeldAtToComputers < ActiveRecord::Migration[8.2]
  def change
    add_column :computers, :held_at, :datetime
  end
end
