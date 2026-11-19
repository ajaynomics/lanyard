# A one-time link for someone outside the install (a client's lawyer, say) to
# put a sign-in into one empty vault entry, so it never passes through an
# agent or a chat (Tool::AskOutsideForSignIn, docs/passwords.md). The agent
# asks for it and the person approves each one; the agent sends it on.
#
# Only its token's digest is kept. Opening it only shows the form, since mail
# scanners fetch links; the first submit uses it up before anything is
# written, so a second, even at the same moment, writes nothing. It lasts 30
# minutes, and ends sooner when the person revokes it. What the visitor types
# goes from that one request to the vault (DurableAssistants::Passbolt.fill),
# never to the database, a job, the log or the thread; the agent hears only
# whether the entry was filled.
class SignInLink < ApplicationRecord
  LASTS = 30.minutes
  # How long a write begun just before the end may still take: passbolt-save's
  # own limit, with room. Only then is a link used with no outcome lost.
  WRITE_LIMIT = 1.minute
  OUTCOMES = %w[ filled failed revoked expired lost ].freeze

  belongs_to :conversation
  belongs_to :invocation
  belongs_to :revoked_by, class_name: "User", optional: true

  validates :outcome, inclusion: { in: OUTCOMES }, allow_nil: true
  delegate :agent, to: :conversation

  # Its card in the thread shows where it stands.
  after_commit -> { invocation.show }, on: :update, if: :saved_change_to_outcome?

  class << self
    # The link and its token, which nothing here keeps.
    def issue!(invocation, entry_id:, name:)
      token = SecureRandom.base58(40)
      link = invocation.conversation.sign_in_links.create!(invocation: invocation, entry_id: entry_id, name: name,
        token_digest: digest(token), expires_at: LASTS.from_now)
      SignInLinkExpiryJob.set(wait_until: link.expires_at + WRITE_LIMIT).perform_later(link)
      [ link, token ]
    end

    def find_by_token(token)
      return unless token.is_a?(String) && token.match?(/\A[A-Za-z0-9]{32,64}\z/)
      find_by(token_digest: digest(token)) # tenancy-ok: the token is the whole of a visitor's claim, and names one link
    end

    def digest(value) = Digest::SHA256.hexdigest(value.to_s)
  end

  def open? = used_at.nil? && outcome.nil? && expires_at.future?

  # Why it no longer takes a sign-in, or nil while it does.
  def why_refused
    if outcome == "revoked" then :revoked
    elsif used_at then :used
    elsif outcome == "expired" || !expires_at.future? then :expired
    end
  end

  # Uses it up, in one update, before anything is written: of two submits at
  # once only one gets true.
  def claim
    now = Time.current
    claimed = conversation.sign_in_links.where(id: id, used_at: nil, outcome: nil).where(expires_at: now..)
      .update_all(used_at: now, updated_at: now) == 1
    reload if claimed
    claimed
  end

  # Writes what the visitor typed into the entry, once: "filled", "failed",
  # or nil when the link was not open to it. A failed write is not retried
  # through this link; the person sends a new one.
  def fill(username:, password:, account: nil)
    return unless claim
    DurableAssistants::Passbolt.fill(agent, entry_id, username: username, password: password, account: account)
    finish("filled")
  rescue DurableAssistants::Passbolt::Error
    finish("failed")
  rescue => error
    # Reported by its class alone: its message might quote what was typed.
    Rails.error.report(RuntimeError.new("A sign-in link's write failed (#{error.class})"), context: { sign_in_link_id: id })
    finish("failed")
  end

  def revoke(by:)
    revoked = with_lock { open? && update!(outcome: "revoked", revoked_by: by) }
    tell if revoked
    revoked
  end

  # Past its end (SignInLinkExpiryJob): unused, it expired; used with no
  # outcome, its write was cut off and nobody knows whether it landed.
  def expire
    ended = with_lock do
      next false if outcome || expires_at.after?(Time.current) || used_at&.after?(WRITE_LIMIT.ago)
      update!(outcome: used_at ? "lost" : "expired")
    end
    tell if ended
  end

  # What the agent is told: whether the entry was filled, never with what.
  def report
    case outcome
    when "filled" then "The sign-in link for #{name} was filled: the entry now has a sign-in. Use it with sign_in_with_saved_password."
    when "failed" then "The sign-in link for #{name} was not filled: what was typed could not be saved to the password manager, " \
      "and the link is used up. Ask the person whether to send a new one."
    when "revoked" then "The sign-in link for #{name} was not filled: #{revoked_by&.name || "the person"} revoked it."
    when "expired" then "The sign-in link for #{name} expired unused: nobody filled it within #{LASTS.inspect}."
    when "lost" then "The sign-in link for #{name} was used, but whether the entry was filled is not known. " \
      "Ask the person to check it in the password manager."
    end
  end

  private
    def finish(result)
      update!(outcome: result)
      tell
      result
    end

    # Once, by its request id: a retry is the same message.
    def tell = SignInLinkReportJob.perform_later(self)
end
