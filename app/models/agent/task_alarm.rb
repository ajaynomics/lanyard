# A reminder that has come due on a task in one of the agent's own task
# lists, and wakes it (#246, docs/calendar.md, "Alarms on its own tasks").
# Only a list its own account owns wakes it: a list merely shared with the
# account, a server it only reads and its linked calendar are another
# account's, and wake whoever owns them.
#
# Rails keeps no copy of the task. Each run reads the lists and takes the
# alarms whose time has just passed, so a task changed on a phone a minute
# ago is read as it is now; the wake carries the alarm's own id, so
# overlapping runs, a retry and a restart wake the agent once.
class Agent::TaskAlarm
  # How far back a run looks: long enough that a minute missed, or an agent
  # busy for a few of them, still wakes it; short enough that a restart does
  # not replay this morning's alarms.
  LOOKBACK = 10.minutes

  # A task nobody is waiting on any more.
  SETTLED = %w[ COMPLETED CANCELLED ].freeze

  NOTES_LIMIT = 2_000
  VIA = "Task alarm".freeze
  ANSWER = "Do what the task needs; nobody is waiting for a reply. calendar_save_task with done completes it.".freeze

  attr_reader :agent, :list, :id, :task, :at

  # Every alarm on the agent's own tasks whose time has just passed.
  def self.due(agent, now: Time.current)
    caldav = agent.own_caldav or return []
    caldav.lists.select { it[:own] && it[:kinds].include?("tasks") }.flat_map do |list|
      caldav.items(list[:list], "tasks").flat_map do |id, _etag, calendar|
        calendar.todos.flat_map { on(agent, list[:list], id, it) }
      end
    end.select { it.at.between?(now - LOOKBACK, now) }
  end

  def self.on(agent, list, id, task)
    return [] if task.status.to_s.upcase.in?(SETTLED)
    task.alarms.filter_map do |alarm|
      at = fires_at(alarm, task, agent.time_zone)
      new(agent, list: list, id: id, task: task, at: at) if at
    end
  end

  # When an alarm fires: the time it names, or so long before the task's
  # start or its due time (RELATED). A reminder for a place fires there, not
  # at a time (Tool::Calendar::Place), and a trigger with nothing to count
  # from is left alone rather than guessed at.
  def self.fires_at(alarm, task, zone)
    return if Tool::Calendar::Place.alarm?(alarm)
    case (trigger = alarm.trigger)
    when Icalendar::Values::Duration then anchor_for(trigger, task, zone)&.+(seconds(trigger))
    when Icalendar::Values::DateTime, Icalendar::Values::Date then moment(trigger, zone)
    end
  end

  # A task's end is its due time and its start its DTSTART. Most tasks carry
  # only one of the two, so a trigger counted from the one it lacks is
  # counted from the other, which is the time the phone that wrote it showed.
  def self.anchor_for(trigger, task, zone)
    ends = Array(trigger.ical_params["related"]).first.to_s.casecmp?("END")
    named, other = ends ? [ task.due, task.dtstart ] : [ task.dtstart, task.due ]
    moment(named, zone) || moment(other, zone)
  end

  def self.seconds(duration)
    parts = duration.value
    whole = ((parts.weeks * 7 + parts.days) * 24.hours) + parts.hours.hours + parts.minutes.minutes + parts.seconds
    parts.past ? -whole : whole
  end

  # A stored time as an instant: a date alone is the start of that day where
  # the agent is.
  def self.moment(value, zone)
    value = value.value if value.respond_to?(:value)
    case value
    when DateTime, Time, Date then value.in_time_zone(zone)
    end
  end

  def initialize(agent, list:, id:, task:, at:)
    @agent, @list, @id, @task, @at = agent, list, id, task, at
  end

  # The alarm's own id, so however many runs see it the agent wakes once.
  def request_id = "alarm:#{agent.id}:#{list}/#{id}:#{at.utc.iso8601}"

  # It waits for the agent's turn to end: a reminder is the agent's own work,
  # not a correction to what it is doing.
  def wake
    agent.conversation.receive(text, from: "your #{list} list", via: VIA, answer: ANSWER,
      request_id: request_id, when_busy: "followUp", sent_at: at)
  end

  private
    # Its words are the task's, as whoever edited it on a phone left them, so
    # they reach the thread untrusted: a task to act on, not instructions.
    def text
      [ title, "Due #{due_in_words}. It is task #{id} on your #{list} list.", notes ].compact.join("\n\n")
    end

    def title = task.summary.to_s.squish.presence || "(this task has no title)"
    def notes = task.description.to_s.strip.presence&.truncate(NOTES_LIMIT)

    # The time it is due as the thread says a time; a date alone is all day.
    def due_in_words
      due = self.class.moment(task.due, agent.time_zone) or return "no time"
      stored = task.due.respond_to?(:value) ? task.due.value : task.due
      stored.is_a?(Date) && !stored.is_a?(DateTime) ? "#{due.to_date.iso8601}, all day" : Conversation.stamp(due, agent.time_zone)
    end
end
