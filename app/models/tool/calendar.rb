require "icalendar/tzinfo"

# What the calendar tools share (docs/calendar.md): the agent's CalDAV
# account, its time zone, and an event or a task as the model sees it. A
# time from the model is a date (all day) or a date and time, in the agent's
# time zone unless it names its offset; one written carries the zone, so a
# repeating event keeps its hour across a change of daylight saving time.
# What the model doesn't name in a change (a phone's alarms, an attendee's
# reply) is written back as it was.
module Tool::Calendar
  extend ActiveSupport::Concern

  WHEN = "^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2}(:[0-9]{2})?(Z|[+-][0-9]{2}:[0-9]{2})?)?$".freeze
  REPEAT = /\AFREQ=(DAILY|WEEKLY|MONTHLY|YEARLY)(;[A-Z]+=[A-Za-z0-9,+-]+)*\z/
  WHEN_HELP = "A date, 2026-11-12, for all day; or a date and time, 2026-11-12T15:00, in your time zone unless it ends with an offset."
  REPEAT_HELP = "An iCalendar RRULE, as FREQ=WEEKLY;BYDAY=MO,WE or FREQ=MONTHLY;BYMONTHDAY=1; empty to stop repeating."
  ID = "^[A-Za-z0-9][A-Za-z0-9_.@-]*$".freeze

  included do
    effect :external
  end

  def permitted? = agent.calendar?

  private
    def caldav = @caldav ||= agent.caldav

    # A list from a server the agent only reads takes nothing: refused here,
    # before anything is read or sent, and again by the client (Caldav::ReadOnly).
    def writable!(list)
      raise Tool::Refusal, DurableAssistants::Caldav::ReadOnly.refusal(list) if caldav.read_only?(list)
    end
    def zone = ActiveSupport::TimeZone[agent.time_zone] || ActiveSupport::TimeZone["UTC"]

    def moment(text)
      text.match?(/\A\d{4}-\d{2}-\d{2}\z/) ? Date.iso8601(text) : zone.iso8601(text)
    rescue ArgumentError
      raise Tool::Refusal, "#{text} is not a date, or a date and time."
    end

    def stored(value, calendar)
      return Icalendar::Values::Date.new(value.strftime("%Y%m%d")) if value.is_a?(Date)
      tzid = zone.tzinfo.name
      calendar.add_timezone(TZInfo::Timezone.get(tzid).ical_timezone(value)) unless calendar.timezones.any? { it.tzid.to_s == tzid }
      Icalendar::Values::DateTime.new(value.in_time_zone(zone).strftime("%Y%m%dT%H%M%S"), "tzid" => tzid)
    end

    # A stored time as a Date (all day) or a time in the agent's zone.
    def plain(value)
      value = value.value if value.respond_to?(:value)
      case value
      when DateTime, Time then value.in_time_zone(zone)
      when Date then value
      end
    end

    def shown_time(value) = plain(value)&.iso8601

    def text(value) = value.to_s.presence

    def repeat!(component, rule)
      return unless rule
      raise Tool::Refusal, "#{rule} is not a repeat rule this understands." unless rule.empty? || rule.match?(REPEAT)
      component.rrule = rule.empty? ? nil : [ rule ]
    end

    # One reminder, so many minutes before (0: at the time); a negative
    # number clears them, and none leaves them as they are. A reminder on
    # arriving somewhere or leaving is not one of these, and stays.
    def alarm!(component, minutes, related: nil)
      return if minutes.nil?
      component.alarms.select! { Place.alarm?(it) }
      return if minutes.negative?
      component.alarm do |alarm|
        alarm.action = "DISPLAY"
        alarm.description = component.summary.to_s
        alarm.trigger = Icalendar::Values::Duration.new("-PT#{minutes}M", related ? { "related" => related } : {}) # zero: PT0S (config/initializers/icalendar.rb)
      end
    end

    def stamp!(component, created: false)
      now = Icalendar::Values::DateTime.new(Time.current.utc.strftime("%Y%m%dT%H%M%SZ"))
      component.dtstamp = component.last_modified = now
      component.created = now if created
      component.sequence = created ? 0 : component.sequence.to_i + 1
    end

    # A new item's calendar and its one component, or the stored ones to change.
    def editing(list, id, kind)
      if id
        etag, calendar = caldav.item(list, id)
        component = (kind == :event ? calendar.events : calendar.todos).find { it.recurrence_id.nil? }
        raise Tool::Refusal, "#{id} in #{list} is not #{kind == :event ? "an event" : "a task"}." unless component
        [ calendar, component, etag, id ]
      else
        calendar = Icalendar::Calendar.new.tap { it.prodid = "-//durable-assistants//EN" }
        component = kind == :event ? calendar.event : calendar.todo
        id = SecureRandom.uuid
        component.uid = "#{id}@durable-assistants"
        stamp!(component, created: true)
        [ calendar, component, nil, id ]
      end
    rescue DurableAssistants::Caldav::Error => error
      # The read comes before the one write, so a failed read changed nothing.
      raise Tool::Refusal, "#{error.message} Nothing was changed."
    end

    def save(list, id, calendar, component, etag)
      stamp!(component) if etag
      caldav.put(list, id, calendar, etag: etag)
    rescue DurableAssistants::Caldav::Error => error
      raise Tool::Refusal, error.message unless error.uncertain?
      return if landed?(list, id, component, error, created: etag.nil?)
      raise Tool::Refusal, "#{error.message} Reading it back shows it did not land, so it is safe to try again."
    end

    # Whether a save the server failed or never answered landed, from the
    # item as stored now. A new item landed if anything is at its id: the id
    # is fresh, so nothing else could have put it there. A change landed if
    # the item carries the SEQUENCE and LAST-MODIFIED this save stamped on it.
    # Anything else (an older version, or one a phone changed since) is "did
    # not land": a retry names the version it read, so if it had landed after
    # all, the server refuses the retry rather than writing it twice.
    def landed?(list, id, sent, error, created:)
      _, calendar = caldav.item(list, id)
      return true if created
      stored = (calendar.events + calendar.todos).find { it.uid.to_s == sent.uid.to_s && it.recurrence_id.nil? }
      stored.present? && [ stored.sequence.to_i, stored.last_modified.to_s ] == [ sent.sequence.to_i, sent.last_modified.to_s ]
    rescue DurableAssistants::Caldav::Error => reread
      return false if reread.status == 404
      raise Tool::Refusal, "#{error.message} Reading it back failed too, so it may or may not have happened; check before trying again.", cause: error
    end

    def event_shown(list, id, event)
      finish = plain(event.dtend)
      finish -= 1 if finish.is_a?(Date) # stored the day after the last; shown as the last, as it is given
      { list: list, id: id, title: event.summary.to_s, start: shown_time(event.dtstart), end: finish&.iso8601,
        all_day: plain(event.dtstart).is_a?(Date), free: event.transp.to_s.upcase == "TRANSPARENT",
        location: text(event.location), notes: text(event.description)&.truncate(2_000),
        repeats: event.rrule.any? || event.recurrence_id.present?, alarms: alarms_shown(event),
        attendees: event.attendee.map { it.to_s.delete_prefix("mailto:") }.presence }.compact
    end

    def task_shown(list, id, task)
      place, proximity = Place.of(task)
      { list: list, id: id, title: task.summary.to_s, due: shown_time(task.due), done: task.status.to_s.upcase == "COMPLETED",
        location: place&.title, proximity: proximity,
        notes: text(task.description)&.truncate(2_000), repeats: task.rrule.any?, alarms: alarms_shown(task) }.compact
    end

    # Each reminder at a time, so the agent can read back one it set (#257):
    # so many minutes before or after the start or end (a task's end is its
    # due time), or at a time. A reminder for a place is shown as the task's
    # place, and one a phone marks never to fire (ACTION:NONE, RFC 9074) is
    # no reminder at all.
    def alarms_shown(component)
      component.alarms.reject { Place.alarm?(it) || it.action.to_s.casecmp?("NONE") }.filter_map do |alarm|
        action = text(alarm.action)&.downcase
        case (trigger = alarm.trigger)
        when Icalendar::Values::Duration
          seconds = Agent::TaskAlarm.seconds(trigger).to_i
          { minutes: minutes(seconds.abs), (seconds.positive? ? :after : :before) => counted_from(component, trigger), action: action }.compact
        when Icalendar::Values::DateTime, Icalendar::Values::Date
          { at: shown_time(trigger), action: action }.compact
        end
      end.presence
    end

    def minutes(seconds) = (seconds % 60).zero? ? seconds / 60 : seconds.fdiv(60).round(2)

    # A task lacking the time its alarm names counts from the one it has, as
    # the alarm fires (Agent::TaskAlarm.anchor_for), so that is the one shown.
    def counted_from(component, trigger)
      ends = Array(trigger.ical_params["related"]).first.to_s.casecmp?("END")
      return ends ? "end" : "start" unless component.is_a?(Icalendar::Todo)
      named, other = ends ? [ component.due, component.dtstart ] : [ component.dtstart, component.due ]
      ends = !ends if named.nil? && other.present?
      ends ? "due" : "start"
    end
end
