# How far each agent's alarms have been read and mailed (AlarmMailerJob).
# Safe across a rolling deploy: code from before ignores it, and an agent
# with none starts reading when it is first read.
class AddAlarmsReadUntilToAgents < ActiveRecord::Migration[8.2]
  def change
    add_column :agents, :alarms_read_until, :datetime
  end
end
