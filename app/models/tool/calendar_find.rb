# Events in a range, each repeating one as its occurrences, or tasks, in one
# list or every list of the kind; optionally only those mentioning some words.
class Tool::CalendarFind < Tool
  include Tool::Calendar

  LIMIT = 100
  # Radicale before 3.9.0 checks a non-repeating event with a TZID against an
  # expanded range by its wall-clock time read as UTC, up to 14 hours out. So
  # the server is asked for this much more on each side, and what overlaps
  # the range asked for is kept here.
  SLACK = 14.hours

  description "Find events between two times, or tasks, in one list or all of them, optionally only those mentioning some words. " \
    "A repeating event comes back as each of its occurrences; its id is the whole series'. " \
    "Each item shows its alarms: so many minutes before or after its start, end or due time, or at a time."
  argument :kind, :string, enum: %w[ events tasks ]
  argument :list, :string, required: false, pattern: Tool::Calendar::ID, description: "One list, as calendar_lists names it. Left out, every list of the kind."
  argument :from, :string, required: false, pattern: Tool::Calendar::WHEN, description: "Events: from when; left out, now. Tasks: only those due from then."
  argument :to, :string, required: false, pattern: Tool::Calendar::WHEN, description: "Events: until when; left out, two weeks after from. Tasks: only those due by then."
  argument :query, :string, required: false, max_length: 200, description: "Words the title, notes or place contain."
  argument :done, :boolean, required: false, description: "Tasks: include those done."

  def call(kind:, list: nil, from: nil, to: nil, query: nil, done: false)
    from = from ? moment(from) : (Time.current if kind == "events")
    to = to ? moment(to) : (from.in_time_zone(zone) + 2.weeks if kind == "events")
    from, to = [ from, to ].map { it.is_a?(Date) ? it.in_time_zone(zone) : it }
    lists = list ? [ list ] : caldav.lists.select { it[:kinds].include?(kind) }.pluck(:list)
    found = lists.flat_map { |name| kind == "events" ? events(name, from, to) : tasks(name, from, to, done) }
    found = found.select { |item| item.values_at(:title, :notes, :location).compact.join(" ").downcase.include?(query.downcase) } if query.present?
    found = found.sort_by { it[:start] || it[:due] || "9999" }
    { kind => found.first(LIMIT), more: (found.size - LIMIT if found.size > LIMIT), unreachable: caldav.unreachable.presence }.compact
  rescue DurableAssistants::Caldav::Error => error
    raise Refusal, error.message
  end

  private
    def events(list, from, to)
      caldav.items(list, "events", from: from - SLACK, to: to + SLACK).flat_map do |id, _, calendar|
        calendar.events.select { overlaps?(it, from, to) }.map { event_shown(list, id, it) }
      end
    end

    # As RFC 4791 matches a time range: an event with no end lasts a day if
    # it is all day, and no time otherwise.
    def overlaps?(event, from, to)
      start = Agent::Alarm.moment(event.dtstart, zone)
      finish = Agent::Alarm.moment(event.dtend, zone) ||
        start + (event.duration ? Agent::Alarm.seconds(event.duration) : (plain(event.dtstart).is_a?(Date) ? 1.day : 0))
      start < to && (finish > from || start == from)
    end

    def tasks(list, from, to, done)
      caldav.items(list, "tasks").flat_map { |id, _, calendar| calendar.todos.map { task_shown(list, id, it) } }.select do |task|
        due = task[:due] && zone.parse(task[:due])
        (done || !task[:done]) && (!from || (due && due >= from)) && (!to || (due && due <= to))
      end
    end
end
