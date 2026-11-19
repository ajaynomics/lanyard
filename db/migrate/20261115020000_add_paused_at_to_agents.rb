# The person may pause an agent (#52): while paused it runs no model turn and
# what it is sent waits (Agent::Pausable). Additive and nullable, so every
# agent stays running, and code from before, during a rolling deploy, neither
# reads nor writes it.
class AddPausedAtToAgents < ActiveRecord::Migration[8.2]
  def change
    add_column :agents, :paused_at, :datetime
  end
end
