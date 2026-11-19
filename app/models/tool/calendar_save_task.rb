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
  argument :location, :string, required: false, max_length: 200,
    description: "A reminder on arriving at or leaving a saved place, by its name, beside any reminder at a time; empty removes it. " \
      "Places are those already on location reminders, as a phone sets them; an unknown one is refused, naming the saved ones."
  argument :proximity, :string, required: false, enum: Tool::Calendar::Place::PROXIMITIES.keys, description: "With location: arrive or leave; left out, as it was, or arrive."

  def call(list:, id: nil, **fields)
    fields = fields.stringify_keys
    writable!(list)
    raise Refusal, "A new task needs a title." unless id || fields["title"].present?
    calendar, task, etag, id = editing(list, id, :task)
    task.summary = fields["title"] if fields["title"].present?
    task.description = text(fields["notes"]) if fields.key?("notes")
    task.due = fields["due"].present? ? stored(moment(fields["due"]), calendar) : nil if fields.key?("due")
    done!(task, fields["done"]) unless fields["done"].nil?
    repeat!(task, fields["repeat"])
    alarm!(task, fields["alarm_minutes"], related: "END")
    place!(task, fields["location"], fields["proximity"]) if fields.key?("location") || fields.key?("proximity")
    save(list, id, calendar, task, etag)
    { saved: task_shown(list, id, task) }
  end

  private
    def place!(task, name, proximity)
      raise Refusal, "A proximity needs a location: the saved place to arrive at or leave." if name.nil?
      return task.alarms.reject! { Place.alarm?(it) } if name.strip.empty?
      places = Place.saved(caldav)
      place = places[name.strip.downcase] or raise Refusal, "No saved place is called #{name.strip}. " \
        "Saved places: #{places.values.map(&:title).sort.join(", ").presence || "none yet"}. " \
        "A place is saved by setting a reminder to fire there on a phone; none is looked up."
      place.alarm!(task, proximity || Place.of(task)&.last || "arrive")
    rescue DurableAssistants::Caldav::Error => error
      raise Refusal, error.message
    end

    def done!(task, done)
      task.status = done ? "COMPLETED" : "NEEDS-ACTION"
      task.completed = done ? Icalendar::Values::DateTime.new(Time.current.utc.strftime("%Y%m%dT%H%M%SZ")) : nil
      task.percent_complete = done ? 100 : nil
    end
end
