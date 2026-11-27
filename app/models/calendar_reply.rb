# A guest's answer to an invitation, as it arrives by mail (RFC 6047 iMIP,
# METHOD:REPLY; docs/calendar.md "Invitations"). It sets that guest's PARTSTAT
# on the stored event, and only then:
#
#   * the UID names an event in one of this agent's own writable lists;
#   * that event is one this agent organises (its ORGANIZER is one of the
#     agent's addresses, Agent#invitation_addresses), so an answer never
#     rewrites someone else's meeting;
#   * the message's From matches the ATTENDEE in the body, and the receiving
#     mail server verified its domain (MailAuthentication).
#
# Anything else is only shown to the agent in words, never applied: mail is
# forgeable, and a stranger must not be able to answer for a guest.
class CalendarReply
  ANSWERS = { "ACCEPTED" => "accepted", "DECLINED" => "declined", "TENTATIVE" => "answered maybe to",
              "DELEGATED" => "passed on" }.freeze

  # The answer in a message, or nil where there is none. The body's METHOD
  # decides, not the Content-Type parameter: the two disagree in the wild.
  def self.in(mail)
    part = calendar_in(mail) or return
    calendar = Icalendar::Calendar.parse(part).first
    return unless calendar&.ip_method.to_s.casecmp?("REPLY")
    event = calendar.events.first or return
    attendee = event.attendee.first or return
    new(uid: event.uid.to_s, attendee: CalendarInvite.mailbox(attendee), partstat: partstat(attendee),
      summary: event.summary.to_s, mail: mail)
  rescue StandardError
    nil # a message that only looks like an answer is just mail
  end

  def initialize(uid:, attendee:, partstat:, summary:, mail:)
    @uid, @attendee, @partstat, @summary, @mail = uid, attendee, partstat, summary, mail
  end

  attr_reader :uid, :attendee, :partstat

  # Applies the answer, and says in one line what happened, for the agent to
  # read above the message itself. Never raises: a message must still reach
  # the agent when the calendar server is down.
  def apply(agent, source: nil)
    return unless agent.calendar?
    return if (addresses = agent.invitation_addresses).empty?
    unless MailAuthentication.new(@mail, source: source).verified? && @mail.from&.first.to_s.downcase == attendee
      return "The calendar answer was not applied because the sender could not be verified."
    end
    return "#{named} names no event of yours (#{uid}), so nothing was changed." unless (found = event_for(agent, addresses))

    list, id, etag, calendar = found
    calendar.events.each { answer!(it) if it.uid.to_s == uid }
    agent.caldav.put(list, id, calendar, etag: etag)
    "#{attendee} #{answered} #{summary(calendar)}. The event in #{list} now shows it."
  rescue DurableAssistants::Caldav::Error => error
    "#{attendee} #{answered} #{@summary.presence || uid}, but the calendar server would not take the change: #{error.message}"
  end

  private
    def self.partstat(attendee) = attendee.ical_params["partstat"].then { Array(it).first.to_s.upcase.presence } || "NEEDS-ACTION"
    private_class_method :partstat

    # The text/calendar part, wherever it sits: a message may be that part
    # alone, or carry it inside a multipart/alternative, or as an attachment.
    def self.calendar_in(mail)
      parts = mail.multipart? ? mail.all_parts : [ mail ]
      found = parts.find { it.mime_type == "text/calendar" } ||
        parts.find { it.filename.to_s.downcase.end_with?(".ics") }
      found&.decoded
    end
    private_class_method :calendar_in

    def named = "A calendar answer for #{@summary.presence || uid}"
    def answered = ANSWERS.fetch(partstat, "answered")
    def summary(calendar) = calendar.events.first&.summary.to_s.presence || @summary.presence || uid

    def answer!(event)
      event.attendee.each do |guest|
        next unless CalendarInvite.mailbox(guest) == attendee
        guest.ical_params["partstat"] = [ partstat ]
        guest.ical_params.delete("rsvp") # answered, so nothing is still being asked of them
      end
    end

    # The event with this UID in a list the agent may write, organised by the
    # agent itself: [ list, id, etag, calendar ].
    def event_for(agent, addresses)
      caldav = agent.caldav
      caldav.lists.select { it[:kinds].include?("events") && !caldav.read_only?(it[:list]) }.each do |list|
        caldav.items(list[:list], "events").each do |id, etag, calendar|
          event = calendar.events.find { it.uid.to_s == uid }
          return [ list[:list], id, etag, calendar ] if event && addresses.any? { CalendarInvite.organised_by?(event, it) }
        end
      end
      nil
    end
end
