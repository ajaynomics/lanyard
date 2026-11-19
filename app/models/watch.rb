# An Apple Watch the person reaches the app from (docs/design.md, "The Watch,
# with its own token"). The phone, signed in, asks for one and hands its token
# to the Watch, which keeps it in its own keychain and sends it with each
# request. Only the token's digest is kept here, so it is seen once, when
# made. Revoked in Settings, it is refused at once.
class Watch < ApplicationRecord
  NAME_LIMIT = 100

  belongs_to :user

  scope :active, -> { where(revoked_at: nil) }

  # The phone app's Settings tab says whether one is connected (SettingsHelper#settings_value); not at
  # each use, which only touches it.
  after_create_commit :refresh_settings
  after_update_commit -> { refresh_settings }, if: :saved_change_to_revoked_at?

  normalizes :name, with: -> { it.to_s.squish.first(NAME_LIMIT).presence || "Apple Watch" }, apply_to_nil: true
  before_create { self.token_digest = self.class.digest(@token = SecureRandom.base58(32)) }

  # The token, once: only on the Watch just made.
  attr_reader :token

  # The active Watch this token was given to. It is found by the token's
  # SHA-256, never compared as written: a lookup's timing could show only
  # part of a digest, and a random token cannot be worked back from one.
  def self.find_by_token(token)
    active.find_by(token_digest: digest(token)) if token.is_a?(String) && token.present? # tenancy-ok: the token names its one Watch
  end

  def self.digest(token) = Digest::SHA256.hexdigest(token)

  def revoke! = update!(revoked_at: Time.current)

  # Once a minute at most: the list is read on every look at the Watch.
  def used!
    touch(:last_used_at) unless last_used_at&.after?(1.minute.ago)
  end

  private
    def refresh_settings = broadcast_refresh_later_to(user, :settings)
end
