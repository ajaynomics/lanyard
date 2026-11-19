# When an agent's mail to people outside the install may go: from, until (local
# HH:MM) and the time zone they are in. Additive and nullable: every existing
# agent, and one made by code from before during a rolling deploy, has none,
# and sends at any hour as before.
class AddSendingHoursToAgents < ActiveRecord::Migration[8.2]
  def change
    add_column :agents, :send_from, :string
    add_column :agents, :send_until, :string
    add_column :agents, :send_time_zone, :string
  end
end
