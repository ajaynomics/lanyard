# Adds an event, or changes the one named by id (a repeating one's whole
# series). Inviting someone outside the install asks the person first, as
# mail to them does: the event then names them, and they are emailed an
# invitation from the agent's own address (Agent#invitation_address, #261), since
# neither CalDAV server this app talks to sends one.
class Tool::CalendarSaveEvent < Tool
  include Tool::Calendar
  include Tool::Inviting

  description "Add an event to a calendar, or change one by its id: only what you name changes, and a new one shows busy unless free. " \
    "People you invite are emailed an invitation, and their answers show on the event. " \
    "Inviting people asks the person first, unless they allowed it always."
  argument :list, :string, pattern: Tool::Calendar::ID, description: "The calendar, as calendar_lists names it."
  argument :id, :string, required: false, pattern: Tool::Calendar::ID, description: "The event to change. Left out, a new one."
  argument :title, :string, required: false, max_length: 500, description: "Needed for a new event."
  argument :start, :string, required: false, pattern: Tool::Calendar::WHEN, description: "Needed for a new event. #{Tool::Calendar::WHEN_HELP}"
  argument :end, :string, required: false, pattern: Tool::Calendar::WHEN, description: "Left out, an hour after the start, or the start's day for all day."
  argument :location, :string, required: false, max_length: 500
  argument :notes, :string, required: false, max_length: 10_000
  argument :repeat, :string, required: false, max_length: 200, description: Tool::Calendar::REPEAT_HELP
  argument :free, :boolean, required: false, description: "Whether the time shows as free (true) or busy (false) to anyone checking. Left out, a new event is busy and a change keeps what it was."
  argument :alarm_minutes, :integer, required: false, minimum: -1, maximum: 40_320, description: "A reminder this many minutes before; -1 removes the reminders."
  argument :invite, :array, required: false, max_items: 20, items: { type: "string", pattern: "^[^@\\s<>,]+@[^@\\s<>,]+$", maxLength: 254 },
    description: "Email addresses to add as attendees."
  asks :approval
  reaches_others

  # The card says plainly what the send does, since allowing the event allows
  # the invitation with it, and names everyone it reaches: the guests already
  # on the event as well as the ones this call adds (Tool::Inviting).
  def approval_title(arguments)
    verb = arguments["id"] ? "Change" : "Add"
    own_address ? "#{verb} #{event_name} and email an invitation to #{guests_in_words}?" : "#{verb} #{event_name} and invite #{guests_in_words}?"
  end

  def approval_note(_arguments)
    return Tool::Inviting::NO_ACCOUNT % agent.name unless own_address
    "#{guests_in_words} #{guests_take} an emailed invitation from #{own_address}, with the event attached. " \
      "Their answers show on the event."
  end

  # Its one recorded send is the invitation (Dispatch).
  def self.dispatch_words(arguments)
    Dispatch::Words.new(noun: "invitation", to: Array(arguments["invite"]).to_sentence.presence || "the event's guests",
      excerpt: arguments["title"].to_s, provider: "the Sent folder of the account it went from",
      log: "the Sent folder for its Message-ID, or ask the guests")
  end

  def call(list:, id: nil, **fields)
    fields = fields.stringify_keys
    writable!(list)
    raise Refusal, "A new event needs a title and a start." unless id || (fields["title"].present? && fields["start"].present?)
    calendar, event, etag, id = editing(list, id, :event)
    event.summary = fields["title"] if fields["title"].present?
    event.location = text(fields["location"]) if fields.key?("location")
    event.description = text(fields["notes"]) if fields.key?("notes")
    times!(calendar, event, fields)
    free!(event, fields["free"], created: etag.nil?)
    repeat!(event, fields["repeat"])
    alarm!(event, fields["alarm_minutes"])
    (invitees - event.attendee.map { it.to_s.delete_prefix("mailto:").downcase }).each { event.append_attendee(Icalendar::Values::CalAddress.new("mailto:#{it}", "rsvp" => "TRUE")) }
    organiser!(event)
    save(list, id, calendar, event, etag)
    { saved: event_shown(list, id, event), **invited(calendar) }
  end

  private
    def invitees = Array(arguments["invite"]).map(&:downcase).uniq

    # The agent organises an event it is inviting to, and goes on organising
    # one it already organises. An event someone else organises (a meeting a
    # phone put in the calendar) is left theirs: this app neither takes it
    # over nor mails its guests.
    def organiser!(event)
      return unless own_address && (invitees.any? || CalendarInvite.organised_by?(event, own_address))
      return if event.organizer.present? && !CalendarInvite.organised_by?(event, own_address)
      event.organizer = Icalendar::Values::CalAddress.new("mailto:#{own_address}")
    end

    # Every guest is emailed, not only the ones named this time: an event that
    # moved must reach everyone already invited to it (iTIP). Only an event
    # this agent organises is one it may invite to; one someone else organises
    # (a meeting a phone put in the calendar) stays theirs, and its guests
    # hear nothing from here.
    def invited(calendar)
      invite = CalendarInvite.new(calendar, organizer: own_address.to_s, zone: zone)
      return {} unless invite.any?
      return { invited: invitation(invite) } if organising?(calendar)
      # With no account of its own there is nothing to organise from: the
      # guests are written on the event, and the call says nothing was sent.
      own_address.nil? && invitees.any? ? { invited: invitation(invite) } : {}
    end

    def organising?(calendar)
      own_address.present? && CalendarInvite.organised_by?(calendar.events.find { it.recurrence_id.nil? }, own_address)
    end

    # A new event is written busy outright rather than left to TRANSP's
    # default, so any reader sees what was meant; a change that doesn't name
    # it leaves the event's own TRANSP, or its absence, alone.
    def free!(event, free, created:)
      event.transp = free ? "TRANSPARENT" : "OPAQUE" unless free.nil? && !created
    end

    def times!(calendar, event, fields)
      return unless fields["start"] || fields["end"]
      start = fields["start"] ? moment(fields["start"]) : plain(event.dtstart)
      finish = fields["end"] ? moment(fields["end"]) : (start.is_a?(Date) ? start + 1 : start + 1.hour)
      finish += 1 if finish.is_a?(Date) && fields["end"] # an all-day event ends the day after its last
      raise Refusal, "The start and end must both be dates, or both times." if start.is_a?(Date) != finish.is_a?(Date)
      raise Refusal, "The end is before the start." if finish < start
      event.dtstart, event.dtend = stored(start, calendar), stored(finish, calendar)
    end
end
