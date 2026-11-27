# A reminder that has come due on an event or a task in one of the agent's
# own lists (docs/calendar.md, "Alarms on its own lists"), which AlarmMailer
# mails to the agent. A list counts only when the server says this account
# owns it. Some servers show a shared list as owned by each member, so an
# item's attendees can narrow which agents it reaches even when the share is
# not visible.
#
# Rails keeps no copy of the item. Each run reads the lists and takes the
# alarms whose time falls in the window it is given, so an item changed on a
# phone a minute ago is read as it is now. The server expands a repeating
# event into its occurrences; a repeat it leaves alone, as it does a task's,
# is expanded here (IceCube), skipping its EXDATEs and any occurrence moved
# to an item of its own (RECURRENCE-ID).
class Agent::Alarm
  # How far ahead of its alarm an item may start: a reminder a week before.
  AHEAD = 8.days

  # A task nobody is waiting on any more, or an event called off.
  SETTLED = %w[ COMPLETED CANCELLED ].freeze

  NOTES_LIMIT = 2_000

  attr_reader :agent, :list, :id, :item, :alarm, :occurrence, :at

  # Every alarm on the agent's own events and tasks that fires after `from`
  # and by `to`, the earliest first.
  def self.due(agent, from:, to:)
    caldav = agent.own_caldav or return []
    within = (from - AHEAD)..(to + AHEAD)
    caldav.lists.select { it[:own] }.flat_map do |list|
      list[:kinds].flat_map do |kind|
        range = { from: within.begin, to: within.end } if kind == "events"
        caldav.items(list[:list], kind, **range.to_h).flat_map { |id, _etag, calendar| in_calendar(agent, list[:list], id, calendar, within) }
      end
    end.select { it.at > from && it.at <= to }.sort_by(&:at)
  end

  def self.in_calendar(agent, list, id, calendar, within)
    items = calendar.events + calendar.todos
    moved = items.filter_map { moment(it.recurrence_id, agent.time_zone) }
    items.flat_map { on(agent, list, id, it, occurrences(it, agent.time_zone, within, moved)) }
  end

  def self.on(agent, list, id, item, occurrences)
    return [] if item.status.to_s.upcase.in?(SETTLED)
    return [] unless addressed_to?(item, agent)
    occurrences.flat_map do |occurrence|
      item.alarms.filter_map do |alarm|
        at = fires_at(alarm, item, agent.time_zone, occurrence)
        new(agent, list: list, id: id, item: item, alarm: alarm, occurrence: occurrence, at: at) if at
      end
    end
  end

  # When each occurrence begins: the item's own time, or each repeat in reach.
  def self.occurrences(item, zone, within, moved)
    first = span(item, zone).compact.first
    return [ first ] if item.rrule.empty? || first.nil?
    schedule = IceCube::Schedule.new(first) do |repeats|
      item.rrule.each { repeats.add_recurrence_rule IceCube::Rule.from_ical(it.value_ical) }
      (item.exdate.flat_map { Array(it.value) }.map { moment(it, zone) } + moved).each { repeats.add_exception_time it }
    end
    schedule.occurrences_between(within.begin, within.end)
  end

  def self.addressed_to?(item, agent)
    named = [ *item.attendee, *(item.organizer if item.attendee.any?) ]
    return true if named.empty?

    # The app address names one agent here; an external mailbox may be shared.
    address = agent.email_address or return false
    named.any? { |attendee| attendee.to_s.casecmp?("mailto:#{address}") }
  end
  private_class_method :addressed_to?

  # When an alarm fires: the time it names, or so long before the
  # occurrence's start or its end (RELATED). A reminder for a place fires
  # there, not at a time (Tool::Calendar::Place), and a trigger with nothing
  # to count from is left alone rather than guessed at.
  def self.fires_at(alarm, item, zone, occurrence)
    return if Tool::Calendar::Place.alarm?(alarm)
    case (trigger = alarm.trigger)
    when Icalendar::Values::Duration then anchor_for(trigger, item, zone, occurrence)&.then { after(it, trigger) }
    when Icalendar::Values::DateTime, Icalendar::Values::Date then moment(trigger, zone)
    end
  end

  # Most tasks carry only one of start and due, so a trigger counted from
  # the one it lacks is counted from the other, which is the time the phone
  # that wrote it showed.
  def self.anchor_for(trigger, item, zone, occurrence)
    start, finish = span(item, zone, occurrence)
    Array(trigger.ical_params["related"]).first.to_s.casecmp?("END") ? finish || start : start || finish
  end

  # An item's start and end, moved to one occurrence: a task's end is its
  # due time, an event's its DTEND.
  def self.span(item, zone, occurrence = nil)
    times = [ moment(item.dtstart, zone), moment(item.is_a?(Icalendar::Todo) ? item.due : item.dtend, zone) ]
    shift = occurrence - times.compact.first if occurrence && times.any?
    times.map { it && shift ? it + shift : it }
  end

  # Days and weeks are calendar days, so a reminder a day before 9:00 is at
  # 9:00 the day before, across a change of clocks too (RFC 5545, 3.3.6).
  def self.after(time, duration)
    parts = duration.value
    whole = (parts.weeks * 7 + parts.days).days + parts.hours.hours + parts.minutes.minutes + parts.seconds.seconds
    parts.past ? time - whole : time + whole
  end

  def self.seconds(duration) = after(Time.at(0).utc, duration) - Time.at(0).utc

  # A stored time as an instant: a date alone is the start of that day where
  # the agent is.
  def self.moment(value, zone)
    value = value.value if value.respond_to?(:value)
    case value
    when DateTime, Time, Date then value.in_time_zone(zone)
    end
  end

  def initialize(agent, list:, id:, item:, alarm:, occurrence:, at:)
    @agent, @list, @id, @item, @alarm, @occurrence, @at = agent, list, id, item, alarm, occurrence, at
  end

  # This alarm on this occurrence: the VALARM's UID (else its place on the
  # item) and the occurrence it fires for, by its RECURRENCE-ID where it was
  # moved, else its start, else the time it fires. Each repeat is its own;
  # however many times one is mailed, the agent reads it once.
  def key
    which = alarm.uid.presence || item.alarms.index(alarm)
    occurs = self.class.moment(item.recurrence_id, agent.time_zone) || occurrence || at
    "#{agent.id}.#{Digest::SHA256.hexdigest("#{list}/#{id}/#{which}@#{occurs.utc.iso8601}").first(32)}"
  end

  def title = item.summary.to_s.squish.presence || "(no title)"

  # Its words are the item's, as whoever edited it on a phone left them.
  def text = [ title, "#{when_in_words}. It is #{kind} #{id} on your #{list} list.", notes ].compact.join("\n\n")

  private
    def task? = item.is_a?(Icalendar::Todo)
    def kind = task? ? "task" : "event"
    def notes = item.description.to_s.strip.presence&.truncate(NOTES_LIMIT)

    # A task's due time or an event's start, as the thread says a time; a date alone is all day.
    def when_in_words
      start, finish = self.class.span(item, agent.time_zone, occurrence)
      time = task? ? finish || start : start
      stored = (task? && item.due) || item.dtstart
      return "Reminder at #{Conversation.stamp(at, agent.time_zone)}" unless time
      all_day = stored.respond_to?(:value) && stored.value.is_a?(Date) && !stored.value.is_a?(DateTime)
      "#{task? ? "Due" : "Starts"} #{all_day ? "#{time.to_date.iso8601}, all day" : Conversation.stamp(time, agent.time_zone)}"
    end
end
