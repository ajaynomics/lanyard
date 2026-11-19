# One file beside a skill's SKILL.md: a reference, a script or an asset
# (docs/skills.md). Rails only stores and shows it; it runs, if at all, on the
# agent's computer.
class Skill::BundledFile < ApplicationRecord
  belongs_to :skill

  before_validation { self.size = content.to_s.bytesize }

  validates :path, presence: true, uniqueness: { scope: :skill_id }

  def text? = Skill::Folder.text?(content)

  # Git's name for these bytes, as a tree on GitHub lists them: an update
  # fetches only the files whose name changed (Skill::Github).
  def git_sha = Skill::Folder.git_sha(content)
end
