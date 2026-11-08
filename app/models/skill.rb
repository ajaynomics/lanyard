# A skill: instructions the agent loads when a task calls for them, as pi's
# skills are (docs/skills.md). The agent's instructions list each skill's name
# and description (Agent#definition); the body reaches the model only when it
# calls read_skill, or when the person types `/skill:name`.
class Skill < ApplicationRecord
  include Agent::Part

  FRONTMATTER = /\A---[ \t]*\r?\n(.*?)\r?\n---[ \t]*(?:\r?\n|\z)(.*)\z/m

  normalizes :name, with: -> { it.strip }
  validates :description, presence: true

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

  def to_s = name
end
