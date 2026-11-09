# Deletes an event (a repeating one's whole series) or a task.
class Tool::CalendarDelete < Tool
  include Tool::Calendar

  description "Delete an event or a task by its id. A repeating event goes whole, every occurrence."
  argument :list, :string, pattern: Tool::Calendar::ID, description: "Its list, as calendar_lists names it."
  argument :id, :string, pattern: Tool::Calendar::ID

  def call(list:, id:)
    etag, = caldav.item(list, id)
    caldav.delete(list, id, etag)
    { deleted: id, list: list }
  rescue DurableAssistants::Caldav::Error => error
    raise Refusal, error.message
  end
end
