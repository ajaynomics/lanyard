# One calendar from another CalDAV account beside the agent's own
# (Agent::LinkedCalendar): the server, the calendar, and the name of the vault
# entry holding the account's sign-in. Never the password itself. Additive:
# every existing agent has none, and code from before ignores the columns.
class AddLinkedCalendarToAgents < ActiveRecord::Migration[8.2]
  def change
    add_column :agents, :linked_calendar_server, :string
    add_column :agents, :linked_calendar, :string
    add_column :agents, :linked_calendar_entry, :string
  end
end
