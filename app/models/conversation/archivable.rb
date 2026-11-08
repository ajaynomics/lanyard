# Archiving keeps the active list short without deleting anything: an
# archived conversation is one stamp away from coming back.
module Conversation::Archivable
  extend ActiveSupport::Concern

  included do
    scope :archived, -> { where.not(archived_at: nil) }
    scope :active, -> { where(archived_at: nil) }
  end

  def archive
    update!(archived_at: Time.current)
  end

  # Every message, the person's or anyone's (Conversation#submit), unarchives,
  # so an archived conversation is never written to unseen.
  def unarchive
    update!(archived_at: nil) if archived?
  end

  def archived? = archived_at.present?
end
