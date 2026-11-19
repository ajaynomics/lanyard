require "net/imap"

# A workspace's own mail domain (#229, docs/email.md, "A workspace's own mail
# domain"): its agents' addresses are at it rather than the install's
# MAIL__DOMAIN, and what they and the app send for them goes from it, through
# the workspace's own server. The install's operator sets it in a console:
# mail for a domain is the domain's owner's to route, and its people's to
# trust.
#
# Like an agent's own mail account (Agent::MailAccount), the password is never
# stored here: it is read from the vault, as the workspace (its own Passbolt
# user, else the install's), for each message and each read, and the entry
# must be saved for the mail server, so it never reaches another host.
#
# With an incoming server, its catch-all box is read each minute
# (WorkspaceMailFetchJob) and its mail routed to the agents it names, as the
# install's is (AgentsMailbox). What is in the box when it is first read is
# not news. Without one, the domain only sends: where a workspace has one
# agent, the provider's catch-all may be that agent's own mailbox, which its
# own inbox reads (Agent::MailAccount::Inbox).
class Workspace::MailDomain < ApplicationRecord
  # The vault entry is missing, empty or saved for another server. One of the
  # agent's own account's kind, so what refuses or reports that refuses or
  # reports this alike (Tool::SendEmail).
  class SignInError < Agent::MailAccount::SignInError; end

  # Its catch-all box is also an agent's own mailbox.
  class SharedMailbox < StandardError; end

  HOST = Agent::MailAccount::HOST
  UNREACHABLE = [ *Agent::MailAccount::Inbox::REFUSED, *Agent::MailAccount::Inbox::UNREACHABLE ].freeze

  belongs_to :workspace

  # The domains whose catch-all box is read, and watched (MailIdler::Box).
  scope :reading, -> { where.not(imap_host: nil) }

  normalizes :domain, :smtp_host, :imap_host, with: -> { it.strip.downcase.delete_suffix(".").presence }
  normalizes :vault_entry, with: -> { it.squish.presence }

  validates :domain, :smtp_host, :vault_entry, presence: true
  validates :domain, format: { with: HOST, message: "must be a plain domain, such as example.com" }, uniqueness: true, allow_nil: true
  validates :domain, exclusion: { in: ->(_) { [ DurableAssistants::Email.domain ] }, message: "is the install's own" }
  validates :smtp_host, format: { with: HOST, message: "must be a plain server name, such as smtp.example.com" }, allow_nil: true
  validates :imap_host, format: { with: HOST, message: "must be a plain server name, such as imap.example.com" }, allow_nil: true
  validates :smtp_port, :imap_port, numericality: { only_integer: true, in: 1..65_535 }
  validates :vault_entry, length: { maximum: 200 }
  validate :imap_host_beside_smtp_host, if: -> { imap_host && smtp_host }

  before_update :read_afresh, if: -> { will_save_change_to_imap_host? || will_save_change_to_imap_port? || will_save_change_to_vault_entry? || will_save_change_to_smtp_host? }

  # How one message reaches its server, for Action Mailer's
  # delivery_method_options: the install's own SMTP settings are left alone.
  # Holds the password, so it is built at the moment of sending and passed
  # nowhere else.
  def delivery_options
    entry = sign_in
    { address: smtp_host, port: smtp_port, domain: domain, user_name: entry.username, password: entry.password,
      authentication: :plain, **encryption }
  end

  # The app's own mail for the workspace (WorkspaceMailer): the install's
  # sender, at this domain, so it is one its server sends for.
  def app_from
    install = Mail::Address.new(DurableAssistants.config(:app, :mailer_from))
    ActionMailer::Base.email_address_with_name("#{install.local}@#{domain}", install.display_name)
  end

  def reads_catch_all? = imap_host.present?

  # The username and password, for one read of its catch-all box or one
  # connection held open on it (MailIdler::Box): read from the vault each
  # time, since only the vault knows the box's user name, and refused where
  # that box is an agent's own.
  def imap_mailbox
    entry = sign_in
    refuse_an_agents_own_mailbox!(entry.username)
    DurableAssistants::Email::Mailbox.new(host: imap_host, port: imap_port, user_name: entry.username, password: entry.password)
  end

  # Its catch-all box's new mail, into Action Mailbox; where it got to, here.
  # The first read starts now. Why a read failed is kept, in our words.
  def fetch_catch_all
    return unless reads_catch_all?
    started = Time.current
    box = imap_mailbox
    validity, last = DurableAssistants::Email.fetch(after: inbox_last_uid, validity: inbox_validity, mailbox: box, since: inbox_read_at || started) do |current, uid, raw|
      ActionMailbox::InboundEmail.create_and_extract_message_id!(raw)
      update_columns(inbox_validity: current, inbox_last_uid: uid)
    end
    update_columns(inbox_validity: validity, inbox_last_uid: last, inbox_read_at: started, inbox_error: nil)
  rescue SignInError, SharedMailbox, *UNREACHABLE => problem
    Rails.logger.warn("Workspace #{workspace_id}'s mail domain: catch-all not read (#{problem.class.name})")
    update_columns(inbox_error: problem_in_words(problem))
  end

  def inspect = "#<#{self.class.name} #{domain} via #{smtp_host}:#{smtp_port}>"

  private
    # Mail refuses tls and starttls together, so each is said outright.
    def encryption
      if smtp_port == Agent::MailAccount::SMTPS then { tls: true, ssl: true, enable_starttls: false, enable_starttls_auto: false }
      else { tls: false, ssl: false, enable_starttls: :always, enable_starttls_auto: false }
      end
    end

    def sign_in
      entry = DurableAssistants::Passbolt.sign_in(workspace, DurableAssistants::Passbolt.find_by_name(workspace, vault_entry).id)
      raise SignInError, "#{vault_entry} has no username and password saved." if entry.username.blank? || entry.password.blank?
      raise SignInError, "#{vault_entry} is saved for #{entry.host || "no address"}, not #{smtp_host}, so it is not sent there." unless entry.host == smtp_host
      entry
    rescue DurableAssistants::Passbolt::Error => error
      raise SignInError, error.message
    end

    # Two readers of one box: the agent's own inbox would see every other
    # agent's mail, and the catch-all would hand the agent's own mail to
    # whoever it names. Only the vault knows the catch-all's user name, so this
    # is asked at each read, not on save. Every workspace's agents, since an
    # address is the install's.
    def refuse_an_agents_own_mailbox!(user_name)
      same_server = Agent::MailAccount.reading.where("lower(imap_host) = ?", imap_host.downcase) # tenancy-ok: one box is one box, whichever workspace's agent reads it
      return unless same_server.includes(:agent).any? { it.signs_in_as?(user_name) }
      raise SharedMailbox, "This catch-all is also an agent's own mailbox, so it is not read: that agent would see every other agent's mail. " \
        "Give the domain a catch-all mailbox no agent owns (docs/email.md)."
    end

    def problem_in_words(problem)
      case problem
      when SignInError, SharedMailbox then problem.message
      when *Agent::MailAccount::Inbox::REFUSED then "#{imap_host} refused the saved sign-in or the inbox."
      when OpenSSL::SSL::SSLError then "#{imap_host} did not offer a trusted TLS connection on port #{imap_port}."
      else "Could not reach #{imap_host} on port #{imap_port} (#{problem.class.name.demodulize})."
      end
    end

    # One saved sign-in serves both servers, so the incoming one must be the
    # mail server or beside it in the same domain, as for an agent's account.
    def imap_host_beside_smtp_host
      parent = smtp_host.split(".", 2).last.to_s
      beside = imap_host == smtp_host || (parent.include?(".") && imap_host.split(".", 2).last == parent)
      errors.add(:imap_host, "must be #{smtp_host} or a server beside it, such as imap.#{parent}") unless beside
    end

    def read_afresh
      self.inbox_validity, self.inbox_last_uid, self.inbox_read_at, self.inbox_error = nil, 0, nil, nil
    end
end
