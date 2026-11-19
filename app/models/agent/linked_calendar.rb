# One calendar from another CalDAV account, such as a family's shared
# calendar on iCloud, beside the agent's own (docs/calendar.md). Its person
# names the server, the one calendar (its collection's address, or its id
# under the server's address) and the vault entry holding the account's
# username and app password. The agent reaches it only through
# DurableAssistants::Caldav::Scoped, and never holds the password.
module Agent::LinkedCalendar
  extend ActiveSupport::Concern

  included do
    normalizes :linked_calendar_server, :linked_calendar, :linked_calendar_entry, with: -> { it.strip.presence }
    validates :linked_calendar_entry, length: { maximum: 200 }
    validate :linked_calendar_is_one_collection, if: -> { linked_calendar_server || linked_calendar }
    validate :linked_calendar_steps_nowhere
  end

  def linked_calendar? = linked_calendar_collection.present? && linked_calendar_entry.present? && DurableAssistants::Passbolt.configured?(self)

  def linked_caldav = DurableAssistants::Caldav::Scoped.new(self, collection: linked_calendar_collection, entry: linked_calendar_entry)

  # The calendar's collection: its full address, or its id or path under the server's.
  def linked_calendar_collection
    return unless linked_calendar_server && linked_calendar
    URI.join(linked_calendar_server.delete_suffix("/") + "/", linked_calendar.delete_suffix("/") + "/")
  rescue URI::Error
    nil
  end

  private
    def linked_calendar_is_one_collection
      collection, server = linked_calendar_collection, (URI(linked_calendar_server.to_s) rescue nil)
      problem =
        if !linked_calendar_server || !linked_calendar then "needs both the server and the calendar"
        elsif !collection || server&.scheme != "https" || collection.scheme != "https" then "must be an https address"
        elsif collection.host != server.host then "must be on the server named"
        elsif collection.userinfo || collection.query || collection.fragment then "must be a plain address, with no sign-in, query or #"
        elsif collection.path.split("/").drop(1).then { it.empty? || it.any? { |segment| segment.in?(%w[ . .. ]) } }
          "must name one calendar, not the server's top"
        end
      errors.add(:linked_calendar, problem) if problem
    end

    # URI.join resolves . and .. away, so /123/calendars/family/../../ would
    # quietly become /123/. What the person typed is checked instead, %2e too,
    # as a server may decode it.
    def linked_calendar_steps_nowhere
      { linked_calendar_server:, linked_calendar: }.each do |attribute, typed|
        segments = typed.to_s.split(/[?#]/, 2).first.to_s.split("/").map { it.gsub(/%2e/i, ".") }
        errors.add(attribute, "must not have . or .. in its path") if segments.intersect?(%w[ . .. ])
      end
    end
end
