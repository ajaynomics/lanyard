# What the agents' own words name outside themselves: a Campfire room, an
# address, an email. Each may mean something else from this install (another
# Campfire's room 12, the other install's host), so each is reported for the
# owner, with where it is here, and none is rewritten: only the owner knows
# which still holds.
class Workspace::Import::References
  WORDS = {
    "agents" => %w[ instructions ],
    "notes" => %w[ body ],
    "prompts" => %w[ body ],
    "skills" => %w[ description body ],
    "skill_bundled_files" => %w[ content ],
    "routines" => %w[ prompt ],
    "document_versions" => %w[ body ]
  }.freeze

  URL = %r{https?://[^\s<>"'`)\]]+}
  EMAIL = /[\w.+-]+@[a-z0-9-]+(?:\.[a-z0-9-]+)+/i
  ROOM = /\brooms?\s+#?(\d+)\b/i

  def initialize(run)
    @run = run
  end

  def all
    words = WORDS.flat_map do |table, columns|
      rows(table).flat_map { |id, row| columns.flat_map { |column| in_words(row[column]).map { |kind, value| entry(table, id, column, kind, value) } } }
    end
    words + rows("campfire_bots").flat_map { |id, row| JSON.parse(row["rooms"].presence || "{}").keys.map { entry("campfire_bots", id, "rooms", "campfire room", it) } }
  end

  private
    def rows(table)
      found = []
      @run.source.each(table) { |row| (id = @run.id(table, row["id"])) && found << [ id, row ] }
      found
    end

    def in_words(text)
      text = text.to_s.dup.force_encoding(Encoding::UTF_8)
      return [] unless text.valid_encoding?
      urls = text.scan(URL).map { it.sub(/[.,;:!?]+\z/, "") }
      rooms = urls.filter_map { it[%r{/rooms/(\d+)}, 1] } + text.scan(ROOM).flatten
      emails = text.gsub(URL, " ").scan(EMAIL).map { it.sub(/\.+\z/, "") }
      (urls.map { [ "url", it ] } + rooms.map { [ "campfire room", it ] } + emails.map { [ "email", it ] }).uniq
    end

    def entry(table, id, column, kind, value) = { "table" => table, "id" => id, "column" => column, "kind" => kind, "value" => value }
end
