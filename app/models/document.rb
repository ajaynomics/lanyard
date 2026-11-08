# What the agent and the person write together beside the thread: the
# canvas (docs/design.md, "Canvas"). One record whatever it holds; its body
# is its newest version, and every version is kept with who wrote it. The
# agent sees the person's changes as a diff on its next message
# (Conversation#submit), so it never works from a stale copy unawares.
class Document < ApplicationRecord
  # A refusal of a targeted edit, said so the agent can fix its call.
  class EditRefused < StandardError; end

  # No HTML or SVG preview: with its scripts sandboxed it still reached the
  # network (docs/design.md, "Canvas"), so a page is code in its language.
  KINDS = { "markdown" => "Markdown", "code" => "Code" }.freeze
  BODY_LIMIT = 200_000
  EXTENSIONS = { "ruby" => "rb", "python" => "py", "javascript" => "js", "typescript" => "ts", "shell" => "sh", "bash" => "sh",
                 "rust" => "rs", "kotlin" => "kt", "csharp" => "cs", "c++" => "cpp", "yaml" => "yml", "markdown" => "md",
                 "text" => "txt", "plaintext" => "txt" }.freeze
  LANGUAGE_NAMES = { "html" => "HTML", "css" => "CSS", "svg" => "SVG", "sql" => "SQL", "json" => "JSON", "yaml" => "YAML", "xml" => "XML",
                     "javascript" => "JavaScript", "typescript" => "TypeScript" }.freeze
  CONTENT_TYPES = { "markdown" => "text/markdown", "code" => "text/plain" }.freeze

  belongs_to :agent
  has_many :versions, -> { order(:number) }, dependent: :delete_all, inverse_of: :document

  validates :title, presence: true, length: { maximum: 200 }, uniqueness: { scope: :agent_id }
  validates :kind, inclusion: { in: KINDS.keys }
  validates :language, format: { with: /\A[\w+#.-]{1,32}\z/ }, allow_blank: true

  normalizes :title, with: -> { it.squish }
  normalizes :language, with: -> { it.strip.downcase.presence }

  # The documents with a version the agent has not seen: the person's.
  scope :changed_since_seen, -> {
    where("documents.seen_version_id IS NOT (SELECT MAX(document_versions.id) FROM document_versions WHERE document_versions.document_id = documents.id)")
  }

  # What goes after the person's words for the agent: each changed
  # document's diff, inside `room` UTF-16 units of the sidecar's limit, and
  # a pointer to read_document for any that does not fit. Message#said takes
  # it off again for the person.
  def self.changes_for_agent(documents, room:)
    intro = "\n\n<document_changes>\nThe person changed these documents in the canvas since you last saw them. Each is a " \
      "unified diff from the version you last saw to theirs; read_document has the whole text.\n"
    room -= Conversation.utf16_length(intro) + 40
    parts = documents.map do |document|
      diff = document.changes_since_seen.presence || "#{document.title} (document #{document.id}): saved again with no change to its lines."
      fits = Conversation.utf16_length(diff) + 2 <= room
      diff = "#{document.title} (document #{document.id}) changed too much to show here; call read_document with document_id #{document.id}." unless fits
      room -= Conversation.utf16_length(diff) + 2
      diff
    end
    "#{intro}\n#{parts.join("\n\n")}\n</document_changes>"
  end

  # Writes a new version, unless the body is the same. The agent has seen
  # what it wrote; a person's version waits for its next message.
  def revise(body, by:)
    raise ArgumentError, "who wrote it: agent or person" unless by.in?(Version::AUTHORS)
    return current_version if current_version && body == self.body
    with_lock do
      version = versions.create!(body: body, author: by, number: (versions.maximum(:number) || 0) + 1)
      @current_version = version
      by == "agent" ? update!(seen_version_id: version.id) : touch
      version
    end
  end

  # Each edit replaces text found exactly once; all apply, or none.
  def edit(edits, by:)
    revise(edits.reduce(body) { |text, edit| replace_once(text, edit.fetch("find"), edit.fetch("replace")) }, by: by)
  end

  def restore(version) = revise(version.body, by: "person")

  def current_version = (@current_version ||= versions.last)
  def body = current_version&.body.to_s
  def number = current_version&.number.to_i

  def seen_version = (versions.find_by(id: seen_version_id) if seen_version_id)
  def changed_since_seen? = current_version.present? && current_version.id != seen_version_id

  def seen! = update!(seen_version_id: current_version&.id)

  # The person's changes since the agent's last look, as a unified diff.
  def changes_since_seen
    seen = seen_version
    Diff.unified(seen&.body.to_s, body, from: "#{title} (document #{id}, version #{seen&.number || 0}, the one you last saw)",
      to: "#{title} (document #{id}, version #{number}, the person's)")
  end

  def reload(...)
    @current_version = nil
    super(...)
  end

  def code? = kind == "code"

  def kind_name = code? && language ? "#{LANGUAGE_NAMES.fetch(language) { language.upcase_first }} code" : KINDS.fetch(kind)

  def filename
    extension = code? ? EXTENSIONS.fetch(language.to_s) { language.to_s.match?(/\A[a-z0-9]{1,8}\z/) ? language : "txt" } : "md"
    "#{title.parameterize.presence || "document"}.#{extension}"
  end

  def content_type = CONTENT_TYPES.fetch(kind)

  def to_s = title

  private
    def replace_once(text, find, replace)
      count = text.scan(find).size
      raise EditRefused, "#{find.truncate(80).inspect} is not in #{title}. Read it again with read_document and copy the text exactly." if count.zero?
      raise EditRefused, "#{find.truncate(80).inspect} is in #{title} #{count} times. Include more of the text around it so it matches once." if count > 1
      text.sub(find) { replace }
    end
end
