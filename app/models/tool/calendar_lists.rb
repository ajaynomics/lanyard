# The calendars and task lists the agent's account holds, its own and those
# shared with it, by the name the other calendar tools take.
class Tool::CalendarLists < Tool
  include Tool::Calendar

  description "List your calendars and task lists, yours and those shared with you, by the list name the other calendar tools take."

  def call
    { lists: caldav.lists, unreachable: caldav.unreachable.presence }.compact
  rescue DurableAssistants::Caldav::Error => error
    raise Refusal, error.message
  end
end
