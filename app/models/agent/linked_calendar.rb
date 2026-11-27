# Calendars from another CalDAV account, such as a family's shared calendars
# on iCloud, beside the agent's own (docs/calendar.md). Its person names the
# server, the calendars (each its collection's address, or its id under the
# server's address, one a line) and the vault entry holding the account's
# username and app password. The agent reaches each only through its own
# DurableAssistants::Caldav::Scoped, and never holds the password.
module Agent::LinkedCalendar
  extend ActiveSupport::Concern

  LIMIT = 20

  included do
    normalizes :linked_calendar_server, :linked_calendar_entry, with: -> { it.strip.presence }
    # A text area's lines; one calendar is saved just as it was before there could be several.
    normalizes :linked_calendar, with: -> { it.lines.map(&:strip).compact_blank.join("\n").presence }
    validates :linked_calendar_entry, length: { maximum: 200 }
    validate :linked_calendars_are_collections, if: -> { linked_calendar_server || linked_calendar }
    validate :linked_calendar_steps_nowhere
  end

  def linked_calendar?
    linked_calendar_collections.any? && linked_calendar_collections.all? && linked_calendar_entry.present? && DurableAssistants::Passbolt.configured?(self)
  end

  def linked_caldavs
    return [] unless linked_calendar?
    linked_calendar_collections.map { DurableAssistants::Caldav::Scoped.new(self, collection: it, entry: linked_calendar_entry) }
  end

  # Each calendar's collection: its full address, or its id or path under the server's.
  def linked_calendar_collections
    return [] unless linked_calendar_server && linked_calendar
    linked_calendar.lines(chomp: true).map do |calendar|
      URI.join(linked_calendar_server.delete_suffix("/") + "/", calendar.delete_suffix("/") + "/")
    rescue URI::Error
      nil
    end
  end

  private
    def linked_calendars_are_collections
      return errors.add(:linked_calendar, "needs both the server and the calendar") unless linked_calendar_server && linked_calendar
      server = URI(linked_calendar_server) rescue nil
      problems = linked_calendar_collections.filter_map { collection_problem(it, server) }.uniq
      # Each is a list named by its address's last part (Caldav::Scoped#list).
      names = linked_calendar_collections.compact.map { it.path.split("/").last }
      problems << "must name calendars with different names" if problems.none? && names.uniq.size < names.size
      problems << "may name at most #{LIMIT} calendars" if linked_calendar_collections.size > LIMIT
      problems.each { errors.add(:linked_calendar, it) }
    end

    def collection_problem(collection, server)
      if !collection || server&.scheme != "https" || collection.scheme != "https" then "must be an https address"
      elsif collection.host != server.host then "must be on the server named"
      elsif collection.userinfo || collection.query || collection.fragment then "must be a plain address, with no sign-in, query or #"
      elsif collection.path.split("/").drop(1).then { it.empty? || it.any? { |segment| segment.in?(%w[ . .. ]) } }
        "must name one calendar, not the server's top"
      end
    end

    # URI.join resolves . and .. away, so /123/calendars/family/../../ would
    # quietly become /123/. What the person typed is checked instead, %2e too,
    # as a server may decode it.
    def linked_calendar_steps_nowhere
      { linked_calendar_server:, linked_calendar: }.each do |attribute, typed|
        segments = typed.to_s.lines(chomp: true).flat_map { it.split(/[?#]/, 2).first.to_s.split("/") }.map { it.gsub(/%2e/i, ".") }
        errors.add(attribute, "must not have . or .. in its path") if segments.intersect?(%w[ . .. ])
      end
    end
end
