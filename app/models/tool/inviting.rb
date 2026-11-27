# What the two calendar tools share when an event has guests (#261,
# docs/calendar.md "Invitations"): who a call will mail, whether a person is
# asked first, and the one way an invitation or a cancellation is sent.
#
# A call that will mail anyone asks exactly as mail to those people does. Its
# recipients are everyone it will mail: the guests already on the event, when
# it is one this agent organises, and any the call names now. So a change that
# names nobody new, and a delete, still ask before they reach an outside
# guest: the approval that invited them covered that invitation's words, not
# whatever is written or cancelled later.
#
# The send is recorded before the server is asked and never made twice
# (Tool::SendsMailOnce), as every other send is. It never raises: the event is
# already written or deleted by then, and a refusal here would send the agent
# back to do that again. What happened goes back in the call's own answer
# instead, in words it can repeat to its person.
module Tool::Inviting
  extend ActiveSupport::Concern
  include Tool::SendsMailOnce

  NO_ACCOUNT = "%s has no mail address to send from, so no invitation was emailed. The guests are written on the event; " \
    "whether they hear of it is up to their own calendar server.".freeze

  # The event could not be read, so who the call would mail is unknown.
  UNREADABLE = :unreadable

  # Everyone the call will mail, which is what a person is asked about and
  # what the card names. None for an event with no guests, or one someone
  # else organises: nothing is mailed about either.
  def recipients = (guests + invitees).uniq

  # The same rule as mail to those people: nothing asks when every one of them
  # is on the install's list, and a person's "Always" with them covers the
  # next one (Agent#allows?). When the event could not be read, who would be
  # mailed is unknown, so it asks rather than slipping past.
  def asks = (guests_known? && recipients.all? { Admission.listed?(it) }) ? nil : super

  private
    # A tool that names people to invite says so; a delete names nobody.
    def invitees = []

    # The address the agent invites from and takes answers at
    # (Agent#invitation_address): its own mail account's, else its address
    # here, which reaches it too (AgentsMailbox), or nil where it has no mail.
    # An invitation must come from a mailbox the agent reads, so the guests'
    # answers come back to it.
    def own_address = agent.invitation_address

    # Whether the call could mail an event's existing guests: only a change or
    # a delete, and only where the agent has an address to invite from.
    def reads_event? = own_address.present? && arguments["id"].present?

    # The stored event, when this agent organises it, read once before anyone
    # is asked: who a call will mail cannot be known without it. One bounded
    # read (DurableAssistants::Caldav::TIMEOUT), kept for the card and the call.
    def stored_event
      return @stored_event if defined?(@stored_event)
      @stored_event = begin
        _, calendar = caldav.item(arguments["list"], arguments["id"])
        event = calendar.events.find { it.recurrence_id.nil? }
        event if event && CalendarInvite.organised_by?(event, own_address)
      rescue DurableAssistants::Caldav::Error => error
        # Nothing is there to mail about; anything else leaves its guests unknown.
        UNREADABLE unless error.status == 404
      end
    end

    def guests_known? = !reads_event? || stored_event != UNREADABLE

    def guests
      return [] unless reads_event? && stored_event.is_a?(Icalendar::Event)
      stored_event.attendee.map { CalendarInvite.mailbox(it) }.uniq - [ own_address ]
    end

    # What the card calls the event, and whom it says the mail goes to. With
    # the event unread, its guests can only be named as such.
    def event_name
      arguments["title"].to_s.squish.presence ||
        (stored_event.summary.to_s.squish.presence if stored_event.is_a?(Icalendar::Event)) || "the event"
    end

    def guests_in_words = recipients.any? ? recipients.to_sentence : "its guests"
    def guests_take = recipients.one? ? "gets" : "get"

    def invitation(invite)
      return { notSent: invite.attendees, why: NO_ACCOUNT % agent.name } unless own_address
      send_once(to: invite.attendees, sender: own_address, domain: own_address.split("@").last,
        tool_name: self.class.tool_name, parts: invite.fingerprint_parts) do |message_id|
        deliver(invite, message_id)
        { sent: invite.attendees, messageId: message_id }
      end
    rescue Tool::Refusal => refusal
      { notSent: invite.attendees, why: refusal.message }
    end

    def deliver(invite, message_id)
      AgentMailer.invitation(agent, invite, message_id: message_id).deliver_now
    rescue *Tool::SendsMailOnce::MAY_HAVE_GONE => problem
      raise Tool::SendsMailOnce::Unanswered, problem.class.name
    rescue Agent::MailAccount::SignInError, Agent::MailAccount::ReadOnly => problem
      raise Tool::Refusal, "#{problem.message.delete_suffix(".")}, so no invitation was emailed."
    end
end
