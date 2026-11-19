require "net/imap"

module DurableAssistants
  # The install's mail settings (config/mail.yml) and the one catch-all
  # mailbox its agents' mail lands in. Rails has no IMAP ingress, so this
  # reads the box and hands each new message to Action Mailbox; Action
  # Mailbox drops a message it already has, so reading one twice is harmless.
  module Email
    def self.setting(key) = DurableAssistants.config(:mail, key)

    def self.domain = setting(:domain)&.downcase

    # Agents have addresses and send mail only with both a domain and a way out.
    def self.configured? = domain.present? && setting(:smtp_address).present?

    def self.inbox? = configured? && setting(:imap_address).present?

    # What an agent may attach to one message: each file, and all together.
    def self.attachment_bytes = setting(:attachment_limit_mb).to_i.megabytes
    def self.attachments_bytes = setting(:attachments_limit_mb).to_i.megabytes

    # A mailbox to read over IMAP with TLS: the install's catch-all, or an
    # agent's own (Agent::MailAccount::Inbox), whose password is read from the
    # vault for one read. Printed without its password.
    Mailbox = Data.define(:host, :port, :user_name, :password) do
      def inspect = "#<Mailbox #{user_name} at #{host}:#{port}>"
      alias_method :to_s, :inspect
    end

    def self.catch_all = Mailbox.new(host: setting(:imap_address), port: setting(:imap_port),
      user_name: setting(:imap_user_name), password: setting(:imap_password))

    # Seconds to connect and finish TLS, then to wait on any one read or
    # write, so a slow but moving download is not cut off. A send waits on
    # its mailbox twice (#219 asks its Sent folder after an answer
    # that never came; #225 files a copy there), so a server that takes the
    # connection and never answers would hold the send up for good. Ten
    # seconds is ample to connect to a working server; twenty with nothing
    # moving, before it is taken as gone. The inbox's reads keep the same.
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 20

    # Swapped in tests, which trust their own certificate authority. Empty is
    # OpenSSL's default: the server's certificate and name are checked.
    singleton_class.attr_accessor :ssl
    self.ssl = {}

    # Net::IMAP bounds only connecting and TLS (open_timeout); past that it
    # waits on its socket for ever, the greeting included. So the socket's own
    # limit (IO#timeout) is set before anything is read: a read or write that
    # outlasts it raises IO::TimeoutError, an IOError, as a dropped connection does.
    class Connection < Net::IMAP
      private
        def tcp_socket(host, port) = super.tap { it.timeout = READ_TIMEOUT }
    end

    def self.connect(mailbox) = Connection.new(mailbox.host, port: mailbox.port, ssl: ssl, open_timeout: OPEN_TIMEOUT)

    # A box watched rather than read (MailIdler): a server holding IDLE sends
    # nothing for as long as the watcher asks, so this one waits far longer on
    # its socket than a read does. Its own limit still ends a connection the
    # network dropped without a word, one IDLE after it was due.
    IDLE_READ_TIMEOUT = 30.minutes

    class Listening < Net::IMAP
      private
        def tcp_socket(host, port) = super.tap { it.timeout = IDLE_READ_TIMEOUT }
    end

    # A connection to one folder of a box, opened read only (EXAMINE) as a
    # read is, ready to be asked to hold IDLE. Nil where the server does not
    # offer IDLE (RFC 2177): there is nothing to watch, and the minute's read
    # is all that box gets.
    def self.listen(mailbox, folder: "INBOX")
      imap = Listening.new(mailbox.host, port: mailbox.port, ssl: ssl, open_timeout: OPEN_TIMEOUT)
      imap.login(mailbox.user_name, mailbox.password)
      if imap.capable?("IDLE")
        imap.examine(Net::IMAP.encode_utf7(folder))
        imap
      else
        imap.disconnect
        nil
      end
    rescue StandardError
      imap&.disconnect
      raise
    end

    # What a server says when the folder it is watching has taken a message:
    # one more in it, or one more it calls recent.
    ARRIVED = %w[ EXISTS RECENT ].freeze

    # Holds one IDLE on an open connection for at most `seconds`, and says
    # whether a message landed while it waited. The caller asks again, so the
    # server never drops the connection for an IDLE that outstayed its welcome
    # (RFC 2177 asks for a fresh one at least every 29 minutes).
    def self.idle(imap, seconds)
      landed = false
      imap.idle(seconds) do |response|
        next unless response.respond_to?(:name) && ARRIVED.include?(response.name.to_s)
        landed = true
        imap.idle_done
      end
      landed
    end

    # Each message the box holds above `after` (an IMAP UID), oldest first, as
    # [validity, uid, raw message]; returns [validity, uid] for where it got to.
    # A box whose UIDVALIDITY changed numbers its messages afresh, so the caller
    # keeps the two together. Such a box, or one never read, is read from the
    # start; or, given `since`, only what the server took after then, so an
    # agent's own box is not taken again from its first message. `folder` is
    # the box's folder by the server's name for it, INBOX unless said; it is
    # opened read only (EXAMINE) and its messages peeked, so nothing is marked.
    def self.fetch(after:, validity:, mailbox: catch_all, folder: "INBOX", since: nil, &message)
      imap = connect(mailbox)
      imap.login(mailbox.user_name, mailbox.password)
      imap.examine(Net::IMAP.encode_utf7(folder))
      current = imap.responses("UIDVALIDITY", &:last)
      return read(imap, current, current == validity ? after : 0, &message) if current == validity || !since
      # Taken before searching, so what arrives meanwhile is above it and read next time.
      newest = imap.responses("UIDNEXT", &:last)&.pred || imap.uid_search([ "ALL" ]).max.to_i
      # SINCE is a day in the server's own zone, so from the day before; the
      # time the server took each message decides.
      taken = imap.uid_search([ "SINCE", (since - 1.day).utc.to_date ]).sort.each_slice(200).flat_map do |slice|
        Array(imap.uid_fetch(slice, "INTERNALDATE")).select { Net::IMAP.decode_time(it.attr["INTERNALDATE"]) >= since.change(usec: 0) }.map { it.attr["UID"] }
      end
      [ current, [ newest, read(imap, current, 0, taken, &message).last ].max ]
    ensure
      imap&.disconnect
    end

    # A Sent folder by the names mail programs give it, for a server that marks none.
    SENT = %r{\A(?:\[Gmail\]/)?Sent(?: Items| Messages| Mail)?\z}i

    # Whether the box's Sent folder holds the message with this Message-ID,
    # after a send whose answer never came (Agent::MailAccount::SentFolder).
    # The folder is the one the server marks \Sent (RFC 6154), else one named
    # as mail programs name it; opened read only (EXAMINE), and asked one
    # SEARCH: nothing is fetched, marked or kept. Nil when it has no Sent
    # folder, which says nothing either way.
    def self.sent?(mailbox, message_id)
      imap = connect(mailbox)
      imap.login(mailbox.user_name, mailbox.password)
      folder = sent_folder(imap) or return
      imap.examine(folder)
      imap.uid_search([ "HEADER", "Message-ID", "<#{message_id}>" ]).any?
    ensure
      imap&.disconnect
    end

    # Files a copy of a message the server just took in the box's Sent
    # folder, found as #sent? finds it, marked read, as a mail program does:
    # some servers file nothing sent over SMTP (Agent::MailAccount::SentFolder).
    # `raw` is the message as it was sent. The folder's name, or nil when it
    # has no Sent folder.
    def self.file_sent(mailbox, raw)
      imap = connect(mailbox)
      imap.login(mailbox.user_name, mailbox.password)
      folder = sent_folder(imap) or return
      imap.append(folder, raw, [ :Seen ])
      folder
    ensure
      imap&.disconnect
    end

    def self.sent_folder(imap)
      folders = Array(imap.list("", "*"))
      (folders.find { it.attr.include?(:Sent) } || folders.find { it.name.match?(SENT) })&.name
    end

    def self.read(imap, current, after, uids = imap.uid_search([ "UID", "#{after + 1}:*" ]))
      uids = uids.select { it > after }.sort
      uids.each_slice(20) do |slice|
        Array(imap.uid_fetch(slice, "BODY.PEEK[]")).each { yield current, it.attr["UID"], it.attr["BODY[]"] }
      end
      [ current, uids.last || after ]
    end
    private_class_method :connect, :read, :sent_folder
  end
end
