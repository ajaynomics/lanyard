# Events in a range, each repeating one as its occurrences, or tasks, in one
# list or every list of the kind; optionally only those mentioning some words.
class Tool::CalendarFind < Tool
  include Tool::Calendar

  LIMIT = 100

  description "Find events between two times, or tasks, in one list or all of them, optionally only those mentioning some words. " \
    "A repeating event comes back as each of its occurrences; its id is the whole series'."
  argument :kind, :string, enum: %w[ events tasks ]
  argument :list, :string, required: false, pattern: Tool::Calendar::ID, description: "One list, as calendar_lists names it. Left out, every list of the kind."
  argument :from, :string, required: false, pattern: Tool::Calendar::WHEN, description: "Events: from when; left out, now. Tasks: only those due from then."
  argument :to, :string, required: false, pattern: Tool::Calendar::WHEN, description: "Events: until when; left out, two weeks after from. Tasks: only those due by then."
  argument :query, :string, required: false, max_length: 200, description: "Words the title, notes or place contain."
  argument :done, :boolean, required: false, description: "Tasks: include those done."
  effect :database

  def call(kind:, list: nil, from: nil, to: nil, query: nil, done: false)
    from = from ? moment(from) : (Time.current if kind == "events")
    to = to ? moment(to) : (from.in_time_zone(zone) + 2.weeks if kind == "events")
    from, to = [ from, to ].map { it.is_a?(Date) ? it.in_time_zone(zone) : it }
    lists = list ? [ list ] : caldav.lists.select { it[:kinds].include?(kind) }.pluck(:list)
    found = lists.flat_map { |name| kind == "events" ? events(name, from, to) : tasks(name, from, to, done) }
    found = found.select { |item| item.values_at(:title, :notes, :location).compact.join(" ").downcase.include?(query.downcase) } if query.present?
    found = found.sort_by { it[:start] || it[:due] || "9999" }
    { kind => found.first(LIMIT), more: (found.size - LIMIT if found.size > LIMIT) }.compact
  rescue DurableAssistants::Caldav::Error => error
    raise Refusal, error.message
  end

  private
    def events(list, from, to)
      caldav.items(list, "events", from: from, to: to).flat_map do |id, _, calendar|
        calendar.events.map { event_shown(list, id, it) }
      end
    end

    def tasks(list, from, to, done)
      caldav.items(list, "tasks").flat_map { |id, _, calendar| calendar.todos.map { task_shown(list, id, it) } }.select do |task|
        due = task[:due] && zone.parse(task[:due])
        (done || !task[:done]) && (!from || (due && due >= from)) && (!to || (due && due <= to))
      end
    end
end
