# A paused agent the person resumed sends what it held before it stops
# holding (#52): resumed_at says it may run again while paused_at still marks
# what is held, so a message that comes meanwhile waits behind those. Additive
# and nullable, so no agent is resuming, and code from before neither reads
# nor writes it.
class AddResumedAtToAgents < ActiveRecord::Migration[8.2]
  def change
    add_column :agents, :resumed_at, :datetime
  end
end
