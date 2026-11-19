# A one-time link to a conversation's screen (Conversations::ScreensController),
# for someone who isn't signed in here: a person types a code into the
# agent's browser from their own phone. Its owner makes it on the screen page
# and sends it on. Only its token's digest is kept, and the page shows the
# link once.
#
# It opens on one device: the first to open it is given a key of its own (in
# an encrypted cookie) and may reload; any other is refused. It lasts ten
# minutes, and ends sooner when its owner ends it or the visitor says Done; a
# screen open through it is cut then too (ScreenRelay). It reaches that
# screen and nothing else: no session, no other page.
class ScreenPass < ApplicationRecord
  LASTS = 10.minutes

  belongs_to :conversation
  belongs_to :created_by, class_name: "User"

  scope :live, -> { where(ended_at: nil).where(expires_at: Time.current..) }

  class << self
    # The pass and its token, which nothing here keeps.
    def issue!(conversation, by:)
      token = SecureRandom.base58(40)
      [ conversation.screen_passes.create!(created_by: by, token_digest: digest(token), expires_at: LASTS.from_now), token ]
    end

    def find_by_token(token)
      return unless token.is_a?(String) && token.match?(/\A[A-Za-z0-9]{32,64}\z/)
      find_by(token_digest: digest(token)) # tenancy-ok: the token is the whole of a visitor's claim, and names one pass
    end

    def digest(value) = Digest::SHA256.hexdigest(value.to_s)
  end

  def live? = ended_at.nil? && expires_at.future?

  # Why it no longer opens, or nil while it does.
  def why_over = (:ended if ended_at) || (:expired unless expires_at.future?)

  # The first device's key, or nil for every later one: claimed in one
  # update, so two opening at once can't both have it.
  def open!
    key, now = SecureRandom.base58(32), Time.current
    claim = { opened_at: now, viewer_digest: self.class.digest(key), updated_at: now }
    return unless self.class.live.where(id: id, opened_at: nil).update_all(claim) == 1
    assign_attributes(claim)
    clear_changes_information
    key
  end

  def viewer?(key)
    key.is_a?(String) && viewer_digest.present? && ActiveSupport::SecurityUtils.secure_compare(viewer_digest, self.class.digest(key))
  end

  def end! = update!(ended_at: ended_at || Time.current)
end
