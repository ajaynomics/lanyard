# Deleting a document keeps it, restorable, for PURGE_AFTER: meanwhile it is
# in no list, read or tool (Agent#documents holds only the kept ones), then
# DocumentPurgeJob removes it with its versions. Who deleted it, the agent or
# a person, is kept beside when, in the words a version uses for who wrote it.
# Restoring it takes its title back, or the next free one if a document has
# that title since.
module Document::Deletable
  extend ActiveSupport::Concern

  PURGE_AFTER = 30.days

  included do
    scope :kept, -> { where(deleted_at: nil) }
    scope :deleted, -> { where.not(deleted_at: nil) }
    scope :due_for_purge, -> { where(deleted_at: ...PURGE_AFTER.ago) }

    validates :deleted_by, inclusion: { in: Document::Version::AUTHORS }, if: :deleted?
  end

  def deleted? = deleted_at.present?

  def soft_delete(by:) = update!(deleted_at: Time.current, deleted_by: by)

  def undelete = update!(deleted_at: nil, deleted_by: nil, title: free_title)

  def purge_at = deleted_at&.+(PURGE_AFTER)

  private
    def free_title
      taken = agent.documents.where.not(id: id).pluck(:title)
      (1..).lazy.map { it == 1 ? title : "#{title.first(190)} (#{it})" }.find { !taken.include?(it) }
    end
end
