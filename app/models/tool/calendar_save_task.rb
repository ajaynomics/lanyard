# Adds a task, or changes, completes or reopens the one named by id.
class Tool::CalendarSaveTask < Tool
  include Tool::Calendar

  description "Add a task to a task list, or change one by its id: only what you name changes. Set done to complete it or reopen it."
  argument :list, :string, pattern: Tool::Calendar::ID, description: "The task list, as calendar_lists names it."
  argument :id, :string, required: false, pattern: Tool::Calendar::ID, description: "The task to change. Left out, a new one."
  argument :title, :string, required: false, max_length: 500, description: "Needed for a new task."
  argument :due, :string, required: false, max_length: 32, description: "#{Tool::Calendar::WHEN_HELP} Empty for none."
  argument :notes, :string, required: false, max_length: 10_000
  argument :done, :boolean, required: false
  argument :repeat, :string, required: false, max_length: 200, description: Tool::Calendar::REPEAT_HELP
  argument :alarm_minutes, :integer, required: false, minimum: -1, maximum: 40_320, description: "A reminder this many minutes before it is due; -1 removes the reminders."

  def call(list:, id: nil, **fields)
    fields = fields.stringify_keys
    raise Refusal, "A new task needs a title." unless id || fields["title"].present?
    calendar, task, etag, id = editing(list, id, :task)
    task.summary = fields["title"] if fields["title"].present?
    task.description = text(fields["notes"]) if fields.key?("notes")
    task.due = fields["due"].present? ? stored(moment(fields["due"]), calendar) : nil if fields.key?("due")
    done!(task, fields["done"]) unless fields["done"].nil?
    repeat!(task, fields["repeat"])
    alarm!(task, fields["alarm_minutes"], related: "END")
    save(list, id, calendar, task, etag)
    { saved: task_shown(list, id, task) }
  end

  private
    def done!(task, done)
      task.status = done ? "COMPLETED" : "NEEDS-ACTION"
      task.completed = done ? Icalendar::Values::DateTime.new(Time.current.utc.strftime("%Y%m%dT%H%M%SZ")) : nil
      task.percent_complete = done ? 100 : nil
    end
end
