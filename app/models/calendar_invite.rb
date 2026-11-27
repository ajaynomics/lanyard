# One event's invitation, as mail carries it (RFC 6047 iMIP, docs/calendar.md
# "Invitations"): the iCalendar object under a METHOD, the words that go with
# it, and the guests it goes to. Neither CalDAV server this app talks to
# schedules, so nothing reaches a guest unless this is emailed.
#
# It is built from the event as it was written, so the invitation carries the
# event's own time zone and its own UID, and a guest's answer comes back
# against that UID. The guests' reminders are their own: VALARMs are left out.
class CalendarInvite
  REQUEST = "REQUEST"
  CANCEL = "CANCEL"
  PRODID = "-//durable-assistants//EN".freeze

  # calendar: the Icalendar::Calendar just written, organizer: the address the
  # agent sends and takes answers from, zone: the agent's time zone.
  def initialize(calendar, organizer:, zone:, ical_method: REQUEST)
    @source, @organizer, @zone, @ical_method = calendar, organizer, zone, ical_method
  end

  def self.cancelling(calendar, organizer:, zone:) = new(calendar, organizer: organizer, zone: zone, ical_method: CANCEL)

  attr_reader :ical_method

  def cancel? = ical_method == CANCEL

  # Whose event this is, as the stored event says: only an event this agent
  # organises is one it may invite to or cancel.
  def self.organised_by?(event, address)
    address.present? && event.organizer.present? && mailbox(event.organizer) == address
  end

  def self.mailbox(address) = address.to_s.delete_prefix("mailto:").downcase

  # Every guest, never the organiser itself: an update goes to everyone
  # already invited, as iTIP asks, not only to whoever was named this time.
  def attendees = event.attendee.map { self.class.mailbox(it) }.uniq - [ @organizer ]

  def any? = event.present? && attendees.any?

  def summary = event.summary.to_s

  def subject
    return "Cancelled: #{summary}" if cancel?
    event.sequence.to_i.positive? ? "Updated invitation: #{summary}" : "Invitation: #{summary}"
  end

  def body
    lines = [ cancel? ? "#{summary} is cancelled." : summary, "", "When: #{when_in_words}" ]
    lines << "Where: #{event.location}" if event.location.present?
    lines << "" << (cancel? ? "Your calendar can take it off." : "Your calendar can answer this invitation; the answer comes back to #{@organizer}.")
    lines.join("\n") + "\n"
  end

  def ics = built.to_ical

  # What makes this the same invitation again, so a retry sends nothing
  # (Dispatch.fingerprint). The stamps are left out: every save writes a new
  # DTSTAMP and SEQUENCE, and resending on those alone would invite twice.
  def fingerprint_parts
    [ ical_method, event.uid.to_s, @organizer, attendees.sort.join(","), summary,
      event.dtstart.to_s, event.dtend.to_s, event.location.to_s, event.rrule.map(&:to_s).join(",") ]
  end

  private
    def event = @event ||= built.events.find { it.recurrence_id.nil? }

    # A copy, so changing it for the guests never touches what was stored:
    # written out and read back is the one way the gem gives a whole calendar,
    # and it keeps the VTIMEZONE the event's times point at.
    def built
      @built ||= Icalendar::Calendar.parse(@source.to_ical).first.tap do |copy|
        copy.ip_method = ical_method
        copy.prodid = PRODID
        copy.events.each { for_guests(it) }
      end
    end

    def for_guests(event)
      event.alarms.clear
      event.organizer = Icalendar::Values::CalAddress.new("mailto:#{@organizer}")
      return unless cancel?
      event.status = "CANCELLED"
      event.sequence = event.sequence.to_i + 1 # a cancellation is one version on, as iTIP asks
    end

    def when_in_words
      start, finish = plain(event.dtstart), plain(event.dtend)
      return "#{start.strftime("%A %-d %B %Y")}, all day" if start.is_a?(Date)
      same_day = finish&.to_date == start.to_date
      "#{start.strftime("%A %-d %B %Y, %-l:%M %p")}#{" to #{finish.strftime(same_day ? "%-l:%M %p" : "%A %-d %B %Y, %-l:%M %p")}" if finish} (#{@zone.name})"
    end

    def plain(value)
      value = value.value if value.respond_to?(:value)
      case value
      when DateTime, Time then value.in_time_zone(@zone)
      when Date then value
      end
    end
end
