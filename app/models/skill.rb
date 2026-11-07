# A skill: instructions the bot loads when a task calls for them, as pi's
# skills are (docs/skills.md). The bot's instructions list each skill's name
# and description (Bot#definition); the body reaches the model only when it
# calls read_skill, or when the person types `/skill:name`.
class Skill < ApplicationRecord
  # pi's rule for a skill's name: lowercase letters, digits, single hyphens.
  NAME = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
  LIMIT = 32
  BODY_BYTES = 32.kilobytes
  FRONTMATTER = /\A---[ \t]*\r?\n(.*?)\r?\n---[ \t]*(?:\r?\n|\z)(.*)\z/m

  belongs_to :bot

  after_save :revise_bot
  after_destroy :revise_bot

  normalizes :name, with: -> { it.strip }
  normalizes :description, with: -> { it.to_s.squish }
  validates :name, length: { maximum: 64 }, uniqueness: { scope: :bot_id },
    format: { with: NAME, message: "may use only a-z, 0-9 and single hyphens" }
  validates :description, presence: true, length: { maximum: 1_024 }
  validates :body, presence: true
  validate :body_fits
  validate :bot_has_room, on: :create

  # A single SKILL.md, as pi writes one: YAML frontmatter with name and
  # description, then the body. Only the file: a skill's bundled scripts would
  # need a computer, and nobody has needed them yet.
  def self.from_markdown(text)
    text = text.to_s.dup.force_encoding(Encoding::UTF_8).scrub
    front, body = text.match(FRONTMATTER)&.captures
    settings = front ? YAML.safe_load(front) : {}
    settings = {} unless settings.is_a?(Hash)
    new(name: settings["name"].to_s, description: settings["description"].to_s, body: (body || text).strip)
  rescue Psych::Exception
    # Unreadable frontmatter leaves no name or description; validation says so.
    new(body: text.strip)
  end

  # The block pi sends when a person types `/skill:name args`
  # (agent-session.ts _expandSkillCommand). There is no folder, so the
  # location names the skill itself.
  def invocation(arguments = nil)
    block = %(<skill name="#{name}" location="skill:#{name}">\n#{body.strip}\n</skill>)
    arguments.present? ? "#{block}\n\n#{arguments.strip}" : block
  end

  def snapshot = { "name" => name, "description" => description, "body" => body }

  def to_s = name

  private
    def body_fits
      errors.add(:body, "must be #{BODY_BYTES / 1.kilobyte} KB or smaller") if body.to_s.bytesize > BODY_BYTES
    end

    def bot_has_room
      errors.add(:base, "#{bot} already has #{LIMIT} skills") if bot && bot.skills.count >= LIMIT
    end

    def revise_bot = bot.record_revision
end
