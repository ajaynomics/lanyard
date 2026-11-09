# Adds an event, or changes the one named by id (a repeating one's whole
# series). Inviting someone outside the install asks the person first, as
# mail to them does: the event then names them, for any calendar that tells
# its attendees.
class Tool::CalendarSaveEvent < Tool
  include Tool::Calendar

  description "Add an event to a calendar, or change one by its id: only what you name changes. " \
    "Inviting people asks the person first, unless they allowed it always."
  argument :list, :string, pattern: Tool::Calendar::ID, description: "The calendar, as calendar_lists names it."
  argument :id, :string, required: false, pattern: Tool::Calendar::ID, description: "The event to change. Left out, a new one."
  argument :title, :string, required: false, max_length: 500, description: "Needed for a new event."
  argument :start, :string, required: false, pattern: Tool::Calendar::WHEN, description: "Needed for a new event. #{Tool::Calendar::WHEN_HELP}"
  argument :end, :string, required: false, pattern: Tool::Calendar::WHEN, description: "Left out, an hour after the start, or the start's day for all day."
  argument :location, :string, required: false, max_length: 500
  argument :notes, :string, required: false, max_length: 10_000
  argument :repeat, :string, required: false, max_length: 200, description: Tool::Calendar::REPEAT_HELP
  argument :alarm_minutes, :integer, required: false, minimum: -1, maximum: 40_320, description: "A reminder this many minutes before; -1 removes the reminders."
  argument :invite, :array, required: false, max_items: 20, items: { type: "string", pattern: "^[^@\\s<>,]+@[^@\\s<>,]+$", maxLength: 254 },
    description: "Email addresses to add as attendees."
  asks :approval
  reaches_others

  def asks = invitees.all? { Admission.admits?(it) } ? nil : super
  def recipients = invitees

  def call(list:, id: nil, **fields)
    fields = fields.stringify_keys
    raise Refusal, "A new event needs a title and a start." unless id || (fields["title"].present? && fields["start"].present?)
    calendar, event, etag, id = editing(list, id, :event)
    event.summary = fields["title"] if fields["title"].present?
    event.location = text(fields["location"]) if fields.key?("location")
    event.description = text(fields["notes"]) if fields.key?("notes")
    times!(calendar, event, fields)
    repeat!(event, fields["repeat"])
    alarm!(event, fields["alarm_minutes"])
    (invitees - event.attendee.map { it.to_s.delete_prefix("mailto:").downcase }).each { event.append_attendee(Icalendar::Values::CalAddress.new("mailto:#{it}", "rsvp" => "TRUE")) }
    save(list, id, calendar, event, etag)
    { saved: event_shown(list, id, event) }
  end

  private
    def invitees = Array(invocation.arguments["invite"]).map(&:downcase).uniq

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
