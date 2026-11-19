# A skill: instructions the agent loads when a task calls for them, as pi's
# skills are (docs/skills.md). The agent's instructions list each ready
# skill's name and description (Agent#definition); the body reaches the model
# only when it calls read_skill, or when the person types `/skill:name`.
#
# A skill is a folder, as the Agent Skills format has it: its SKILL.md is
# this row, and the files beside it (references, scripts, assets) are its
# bundled files, which go to the agent's computer when it reads the skill
# (Skill::OnComputer). A skill with a program among them waits for a person
# to review it, and again whenever its files change.
class Skill < ApplicationRecord
  include Agent::Part, OnComputer, Review

  FRONTMATTER = /\A---[ \t]*\r?\n(.*?)\r?\n---[ \t]*(?:\r?\n|\z)(.*)\z/m

  has_many :files, -> { order(:path) }, class_name: "Skill::BundledFile", inverse_of: :skill, dependent: :delete_all

  normalizes :name, with: -> { it.strip }
  validates :description, presence: true

  # A SKILL.md, as pi writes one: YAML frontmatter with name and description,
  # then the body.
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

  # A whole folder (Skill::Folder): its SKILL.md, then each file beside it.
  def self.from_folder(folder, **source)
    from_markdown(folder.markdown).tap do |skill|
      skill.assign_attributes(source)
      skill.take_files(folder)
    end
  end

  # The block pi sends when a person types `/skill:name args`
  # (agent-session.ts _expandSkillCommand). A skill with no folder on a
  # computer names itself as its location.
  def invocation(arguments = nil, computer: nil)
    block = if on_computer?(computer)
      %(<skill name="#{name}" location="#{location}/#{Folder::MARKDOWN}">\nReferences are relative to #{location}. ) +
        %(Call read_skill with #{name} first to put its files there.\n\n#{body.strip}\n</skill>)
    else
      %(<skill name="#{name}" location="skill:#{name}">\n#{body.strip}\n</skill>)
    end
    arguments.present? ? "#{block}\n\n#{arguments.strip}" : block
  end

  def snapshot
    super.merge({ "state" => (state unless ready?), "files" => (files.map { { "path" => it.path, "sha" => it.git_sha } } if files.any?) }.compact)
  end

  # The same skill for another agent ("New agent from here"): its files, its
  # review and where it came from, so nothing unreviewed becomes ready.
  # Its state, instructions and files as one version, read in one
  # transaction, so a change made meanwhile is copied whole or not at all.
  def copy_to(agent)
    source = transaction { self.class.includes(:files).find(id) }
    agent.skills.new(source.slice(:name, :description, :body, :state, :github_repo, :github_path, :github_ref, :github_sha)).tap do |copy|
      copy.files = source.files.map { it.slice(:path, :content, :executable) }.map { Skill::BundledFile.new(it) }
    end
  end

  def github? = github_repo.present?

  # Where on GitHub it came from, at the commit it is pinned to.
  def github_url = ("https://github.com/#{github_repo}/tree/#{github_sha}/#{github_path}".chomp("/") if github?)

  def github_source = ([ github_repo, github_path.presence ].compact.join("/") if github?)

  def to_s = name
end
