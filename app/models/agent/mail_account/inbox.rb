require "net/imap"

# The agent's own inbox, read each minute (MailAccountFetchJob) over IMAP with
# TLS, signed in with the account's one vault entry (docs/email.md, "Its own
# mail account"). New mail reaches this agent's thread alone, as untrusted
# mail (ReceivedMail): nothing in it is routed to the agents it names.
#
# Where the password may go: the entry must be saved for the mail server
# (smtp_host), as for sending. The incoming server is that same server or one
# beside it in the same domain (imap.example.com beside smtp.example.com),
# both typed by the workspace's owner, so the password never reaches a domain
# it was not saved for. A mailbox only read has no mail server: its entry is
# saved for the incoming server itself.
#
# The box is only read: opened with EXAMINE, fetched with BODY.PEEK, nothing
# marked, moved or deleted. Where it got to is kept here, with the box's
# UIDVALIDITY; for a mailbox only read, each of its folders keeps its own
# (Agent::MailAccount::Folder). Mail already in a folder when it is first
# read is not news; a folder renumbered is read again from the last good
# read, and what the thread already had is dropped by its request id.
module Agent::MailAccount::Inbox
  extend ActiveSupport::Concern

  # What a server or the network may raise; said in our words, never its own,
  # which could echo what it was sent.
  REFUSED = [ Net::IMAP::NoResponseError, Net::IMAP::BadResponseError ].freeze
  UNREACHABLE = [ Net::IMAP::Error, IOError, SystemCallError, SocketError, OpenSSL::SSL::SSLError, Timeout::Error ].freeze
  # What a mailbox only read reads, unless its owner names others: the
  # server's own names for them, as its mail program shows them.
  FOLDERS = "INBOX, Sent, Drafts"
  FOLDER = /\A[^\x00-\x1f*%"\\]{1,100}\z/ # one folder's name: no wildcard, quote or control character

  included do
    has_many :folders, class_name: "Agent::MailAccount::Folder", dependent: :delete_all
    scope :reading, -> { where.not(imap_host: nil) }
    normalizes :folder_names, with: -> { it.split(",").map(&:strip).compact_blank.uniq.join(", ").presence }
    validate :imap_host_beside_smtp_host, if: -> { imap_host && smtp_host }
    validate :folders_are_names, if: :read_only?
    before_validation -> { self.folder_names ||= FOLDERS }, if: :read_only?
    before_update :read_afresh, if: -> { will_save_change_to_imap_host? || will_save_change_to_imap_port? || will_save_change_to_vault_entry? || will_save_change_to_smtp_host? }
  end

  def reads_inbox? = imap_host.present? && usable?

  # The folders read: a mailbox only read, those named; the sending account, its INBOX.
  def folder_list = read_only? ? folder_names.to_s.split(", ") : [ "INBOX" ]

  def fetch_inbox
    return unless reads_inbox?
    box = imap_mailbox
    if read_only?
      folder_list.each do |name|
        @reading = name
        read_folder(box, name, folders.find_or_create_by!(name: name))
      end
    else
      read_folder(box, "INBOX", self)
    end
    update_columns(inbox_error: nil)
  rescue Agent::MailAccount::SignInError, *UNREACHABLE => problem
    Rails.logger.warn("Mail account #{id}: inbox not read (#{problem.class.name})")
    update_columns(inbox_error: problem_in_words(problem))
  end

  # Whether a user name signs in to this very box on its incoming server: its
  # address, or the user name its own saved sign-in holds. A sign-in it can't
  # read now is no box it reads either (Workspace::MailDomain#fetch_catch_all).
  def signs_in_as?(user_name)
    wanted = user_name.to_s.strip.downcase
    address == wanted || (reads_inbox? && sign_in.username.to_s.strip.downcase == wanted)
  rescue Agent::MailAccount::SignInError
    false
  end

  # Where the sending account's INBOX got to, in its own columns as before;
  # a folder of a mailbox only read keeps its own (Folder#place).
  def place = [ inbox_validity, inbox_last_uid, inbox_read_at ]
  def place!(validity, uid, read_at = nil) = update_columns({ inbox_validity: validity, inbox_last_uid: uid, inbox_read_at: read_at }.compact)

  # The username and password, for one read of this box or one connection
  # held open on it (MailIdler::Box): read from the vault each time, and kept
  # no longer than the connection it is for.
  def imap_mailbox
    raise Agent::MailAccount::SignInError, "#{imap_host} is not beside #{smtp_host}, so the saved sign-in is not sent there." unless read_only? || beside_smtp_host?
    entry = sign_in
    DurableAssistants::Email::Mailbox.new(host: imap_host, port: imap_port, user_name: entry.username, password: entry.password)
  end

  # Signed in to the box for one call of the agent's own mail tools
  # (Tool::ReadOwnMail, Tool::ChangeOwnMail). What went wrong is said in our words, never the server's.
  def with_mailbox(&)
    DurableAssistants::Email.session(imap_mailbox, &)
  rescue *REFUSED
    raise Agent::MailAccount::Unreachable, "#{imap_host} refused the sign-in or what was asked of it: check the folder's name."
  rescue Agent::MailAccount::SignInError, *UNREACHABLE => problem
    raise Agent::MailAccount::Unreachable, problem_in_words(problem)
  end

  private
    def read_folder(box, name, state)
      started = Time.current
      validity, after, read_at = state.place
      validity, last = DurableAssistants::Email.fetch(after: after, validity: validity, mailbox: box, folder: name,
        since: read_at || started) do |current, uid, raw|
        take(Mail.new(raw), raw, name)
        state.place!(current, uid)
      end
      state.place!(validity, last, started)
    end

    # Its own mail, a copy of what it sent, or mail from its Always Bcc is
    # not news, and would answer itself. In a mailbox only read, every message
    # is: its Sent is all its own address's, and it is what the agent took over.
    def take(mail, raw, folder)
      return if !read_only? && (Array(mail.from).map(&:downcase) & [ address, agent.email_address, forced_bcc ].compact).any?
      ReceivedMail.new(mail, message_id: mail.message_id.presence || "#{Digest::SHA1.hexdigest(raw)}@#{imap_host}",
        found_in: ([ address, folder ] if read_only?)).deliver_to(agent)
    end

    def problem_in_words(problem)
      case problem
      when Agent::MailAccount::SignInError then problem.message
      when *REFUSED then "#{imap_host} refused the saved sign-in or #{read_only? ? "the folder #{@reading}" : "the inbox"}."
      when OpenSSL::SSL::SSLError then "#{imap_host} did not offer a trusted TLS connection on port #{imap_port}."
      else "Could not reach #{imap_host} on port #{imap_port} (#{problem.class.name.demodulize})."
      end
    end

    def beside_smtp_host?
      domain = smtp_host.to_s.split(".", 2).last.to_s
      imap_host == smtp_host || (domain.include?(".") && imap_host.to_s.split(".", 2).last == domain)
    end

    def imap_host_beside_smtp_host
      errors.add(:imap_host, "must be #{smtp_host} or a server beside it, such as imap.#{smtp_host.split(".", 2).last}") unless beside_smtp_host?
    end

    def folders_are_names
      list = folder_list
      errors.add(:folder_names, "must name at least one folder, and at most 10") unless list.size.in?(1..10)
      errors.add(:folder_names, "must be folder names separated by commas, with no * % \" or \\") unless list.all? { it.match?(FOLDER) }
    end

    def read_afresh
      self.inbox_validity, self.inbox_last_uid, self.inbox_read_at, self.inbox_error = nil, 0, nil, nil
      folders.delete_all
    end
end
