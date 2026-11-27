# Deletes an event (a repeating one's whole series) or a task. An event the
# agent organises and has guests on is cancelled with them too: a METHOD:CANCEL
# by mail (CalendarInvite, #261), since the calendar servers send nothing.
# Because that reaches other people, a delete that will mail anyone outside
# the install asks the person first, as mail to them does; a task, an event
# with no guests, and an event someone else organises mail nobody and ask
# nothing, as before.
class Tool::CalendarDelete < Tool
  include Tool::Calendar
  include Tool::Inviting

  description "Delete an event or a task by its id. A repeating event goes whole, every occurrence. " \
    "Guests of an event you organise are emailed that it is cancelled, which asks the person first."
  argument :list, :string, pattern: Tool::Calendar::ID, description: "Its list, as calendar_lists names it."
  argument :id, :string, pattern: Tool::Calendar::ID
  asks :approval
  reaches_others

  def approval_title(_arguments) = "Delete #{event_name} and email a cancellation to #{guests_in_words}?"

  def approval_note(_arguments)
    "#{guests_in_words} #{guests_take} an email from #{own_address} saying it is off, and their calendars take it away. " \
      "Deleting it here cannot be undone."
  end

  # Its one recorded send is the cancellation (Dispatch).
  def self.dispatch_words(arguments)
    Dispatch::Words.new(noun: "cancellation", to: "the event's guests", excerpt: arguments["id"].to_s,
      provider: "the Sent folder of the account it went from", log: "the Sent folder for its Message-ID, or ask the guests")
  end

  def call(list:, id:)
    writable!(list)
    etag, calendar = caldav.item(list, id)
    invite = cancellation(calendar)
    caldav.delete(list, id, etag)
    { deleted: id, list: list, **(invite ? { cancelled: invitation(invite) } : {}) }
  rescue DurableAssistants::Caldav::Error => error
    raise Refusal, error.message
  end

  private
    # Built before the delete, from the event as it stands, and sent after it:
    # nothing is cancelled to the guests that is still in the calendar.
    def cancellation(calendar)
      event = calendar.events.find { it.recurrence_id.nil? } or return
      return unless CalendarInvite.organised_by?(event, own_address)
      CalendarInvite.cancelling(calendar, organizer: own_address, zone: zone).then { it if it.any? }
    end
end
