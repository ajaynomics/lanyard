# An agent's own mail account (docs/email.md, "Its own mail account", #77):
# the address it sends from, the server it sends through and the name of the
# vault entry holding the mailbox's username and password. Like a linked
# calendar (Agent::LinkedCalendar), the password is never stored here: it is
# read from the vault, as the agent, for each message and dropped after it.
# Only the owner sets it, and the forced Bcc with it, on the agent's Channels.
# With an incoming server, its inbox is read too (Agent::MailAccount::Inbox),
# its Sent folder given a copy of each message its server took, and asked,
# after a send that went unanswered, whether it holds that one message
# (Agent::MailAccount::SentFolder).
#
# Or a mailbox it only reads (read_only), such as a colleague's whose work it
# took over ("Read-only mailboxes"): its folders are read, and nothing is ever
# sent, drafted or written there. It has no server to send through and no
# Bcc, and its sign-in is saved for its incoming server. An agent sends
# through one account at most, the one not read only (Agent#mail_account).
#
# Its owner may make that one its only address (primary, "Its only
# address"): mail goes from it or not at all, never the install's way, the
# agent is told no other address, and mail to its address here is turned
# away (AgentsMailbox).
class Agent::MailAccount < ApplicationRecord
  # A name a server answers to, with no scheme, port, path or sign-in: those
  # would let "smtp.example.com@elsewhere.example" send the password elsewhere.
  HOST = /\A(?=.{1,253}\z)[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+\z/
  ADDRESS = /\A[^@\s<>,;:"()\[\]\\]{1,64}@#{HOST.source.delete_prefix('\A')}/
  SMTPS = 465 # TLS from the start; any other port upgrades with STARTTLS, or sends nothing

  # The vault entry is missing, empty or saved for another server; in words a
  # person or a model can read, never with the password.
  class SignInError < StandardError; end

  # Mail was about to leave through a mailbox the agent only reads.
  class ReadOnly < StandardError; end

  include Inbox, SentFolder

  belongs_to :agent

  normalizes :address, :forced_bcc, :smtp_host, :imap_host, with: -> { it.strip.downcase.delete_suffix(".").presence }
  normalizes :display_name, :vault_entry, with: -> { it.squish.presence }

  scope :sending, -> { where(read_only: false) }

  validates :agent_id, uniqueness: { conditions: -> { sending } }, unless: :read_only?
  validates :address, presence: true, format: { with: ADDRESS, message: "must be one plain email address" }, length: { maximum: 254 }
  validates :address, uniqueness: { scope: :agent_id, message: "is already one of its mailboxes" }
  validates :forced_bcc, format: { with: ADDRESS, message: "must be one plain email address" }, length: { maximum: 254 }, allow_nil: true
  validates :smtp_host, presence: true, format: { with: HOST, message: "must be a plain server name, such as smtp.example.com" }, unless: :read_only?
  validates :smtp_host, :forced_bcc, absence: true, if: :read_only?
  validates :imap_host, presence: true, if: :read_only?
  validates :imap_host, format: { with: HOST, message: "must be a plain server name, such as imap.example.com" }, allow_nil: true
  validates :smtp_port, :imap_port, numericality: { only_integer: true, in: 1..65_535 }
  validates :display_name, length: { maximum: 100 }
  validates :vault_entry, presence: true, length: { maximum: 200 }
  validates :primary, absence: { message: "can't be a mailbox it only reads" }, if: :read_only?
  # A mailbox read only never becomes one to send from, nor the other way.
  attr_readonly :read_only

  # Mail goes this way only where the agent can read the vault; otherwise the
  # install's way, as before. The forced Bcc goes either way (AgentMailer).
  def usable? = DurableAssistants::Passbolt.configured?(agent)

  def from = ActionMailer::Base.email_address_with_name(address, display_name || agent.name)

  # As its only address, mail it can't send this way is not sent at all,
  # rather than going from its address here (AgentMailer, Tool::SendEmail).
  def refuse_unusable!
    raise SignInError, "#{agent.name} can't read the password manager, and it sends only from #{address}." if primary? && !usable?
  end

  # The belt to Agent#mail_account's braces: mail never leaves through a
  # mailbox the agent only reads (AgentMailer, Tool::SendEmail).
  def refuse_sending!
    raise ReadOnly, "#{address} is read only: nothing is sent or drafted from it." if read_only?
  end

  # How this one message reaches the server, for Action Mailer's
  # delivery_method_options: the install's own SMTP settings are left alone.
  # Holds the password, so it is built at the moment of sending and passed
  # nowhere else.
  def delivery_options
    refuse_sending!
    entry = sign_in
    { address: smtp_host, port: smtp_port, domain: address.split("@").last, user_name: entry.username, password: entry.password,
      authentication: :plain, **encryption }
  end

  def inspect = "#<#{self.class.name} #{address} #{read_only? ? "read only from #{imap_host}" : "via #{smtp_host}:#{smtp_port}"}>"

  private
    # Mail refuses tls and starttls together, so each is said outright, over
    # whatever the install's own settings hold.
    def encryption
      if smtp_port == SMTPS then { tls: true, ssl: true, enable_starttls: false, enable_starttls_auto: false }
      else { tls: false, ssl: false, enable_starttls: :always, enable_starttls_auto: false }
      end
    end

    # The server the vault entry must be saved for: the mail server, or, for a
    # mailbox only read, its incoming server, the only one it has.
    def signs_in_at = read_only? ? imap_host : smtp_host

    # The entry must be saved for the server it is sent to, as a linked
    # calendar's is (DurableAssistants::Caldav::Scoped): a password shared
    # with the agent for one site never goes to another.
    def sign_in
      entry = DurableAssistants::Passbolt.sign_in(agent, DurableAssistants::Passbolt.find_by_name(agent, vault_entry).id)
      raise SignInError, "#{vault_entry} has no username and password saved." if entry.username.blank? || entry.password.blank?
      raise SignInError, "#{vault_entry} is saved for #{entry.host || "no address"}, not #{signs_in_at}, so it is not sent there." unless entry.host == signs_in_at
      entry
    rescue DurableAssistants::Passbolt::Error => error
      raise SignInError, error.message
    end
end
