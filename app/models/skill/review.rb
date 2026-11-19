# A skill with files beside its SKILL.md waits for a person before the agent
# sees it: they go to the agent's computer, and any of them could be run, so
# a person reads them first, as they decide which tools an agent may use.
# Which files look like programs only labels them; it decides nothing.
# Approval covers the whole folder as read: any change to SKILL.md or to its
# files asks again. Rails stores and shows a skill's files; it never runs them.
module Skill::Review
  extend ActiveSupport::Concern

  # The page changed under the person: what they read is not what is there.
  class Stale < StandardError; end

  included do
    enum :state, %w[ ready needs_review rejected ].index_by(&:itself), default: "ready", validate: true
    before_save :ask_again, if: :instructions_changed?
  end

  # The folder's files, replacing any it had; with any files, before or
  # after, it waits for review.
  def take_files(folder)
    had_files = files.any?
    self.files = folder.bundled.map { Skill::BundledFile.new(path: it.path, content: it.content, executable: it.executable) }
    self.state = had_files || files.any? ? "needs_review" : "ready"
  end

  # A newer version of the same skill, from where it came (Skill::Github).
  def replace_with(folder, github_sha:)
    incoming = self.class.from_markdown(folder.markdown)
    raise Skill::Folder::Invalid, "The skill there is called #{incoming.name.presence || 'nothing'} now, not #{name}. Add it as a new skill instead." if incoming.name != name
    transaction do
      assign_attributes(description: incoming.description, body: incoming.body, github_sha: github_sha)
      take_files(folder)
      save!
    end
  end

  # Those that look like programs, for the page to mark.
  def programs = files.select(&:executable)

  # What the review is about, in words: programs if any look like one.
  def review_reason = programs.any? ? "programs in it" : "files with it"

  # What the person read: the instructions and every file, so approving a page
  # opened before an update approves nothing.
  def contents_digest
    Digest::SHA256.hexdigest([ name, description, body, *files.map { "#{it.path} #{it.executable} #{Digest::SHA256.hexdigest(it.content)}" } ].join("\n"))
  end

  def approve!(digest)
    with_lock do
      raise Stale unless digest == contents_digest
      update!(state: "ready")
    end
  end

  def reject! = update!(state: "rejected")

  private
    # Its SKILL.md is part of what was read: an edit to a skill with files
    # asks again, as a new version of its files does.
    def ask_again
      self.state = "needs_review" if files.any?
    end

    def instructions_changed? = persisted? && !will_save_change_to_state? && (changed & %w[ name description body ]).any?
end
