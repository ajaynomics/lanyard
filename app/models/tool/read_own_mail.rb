# Searches and reads the agent's own mail account (docs/email.md, "Its own
# mail, searched"), what it sent and received, so it never asks a person to
# look. Only its own sending accounts with an incoming server: never another
# agent's, nor a mailbox it only reads, refused before any connection opens.
# Reading changes nothing, so nothing asks first: each folder is opened read
# only (EXAMINE) and its messages peeked, so none is marked read. A search
# is one page, newest first; `older` is where the next one starts, a uid.
class Tool::ReadOwnMail < Tool
  include Tool::OwnMail

  PAGE = 20
  FETCHED = 1_000_000 # bytes of one message read whole, attachments included
  HEADERS = 10_000
  TEXT = 20_000
  WORDS = { required: false, max_length: 200 }.freeze
  DAY = { required: false, pattern: "^\\d{4}-\\d{2}-\\d{2}$" }.freeze

  description "Search or read your own mail account: what you sent and received. With list_folders, its folders. Otherwise one folder " \
    "(INBOX unless named; Sent is your sent mail), newest first, #{PAGE} at a time: each message's uid, message_id, from, to, subject, " \
    "date and in_reply_to. For older ones, call again with older as returned. With message_id, that one message whole: its headers " \
    "and text." + McpServer::Google::DATA
  argument :account, :string, required: false, max_length: 254, description: "Which of your own addresses; your default when left out."
  argument :list_folders, :boolean, required: false, description: "List the folders instead."
  argument :folder, :string, required: false, max_length: 100, description: "INBOX, Sent, or a folder as listed; INBOX when left out."
  argument :from, :string, **WORDS, description: "Part of the sender's name or address."
  argument :to, :string, **WORDS, description: "Part of a recipient's name or address."
  argument :subject, :string, **WORDS, description: "Part of the subject."
  argument :since, :string, **DAY, description: "Filed on or after this day, YYYY-MM-DD."
  argument :through, :string, **DAY, description: "Filed on or before this day, YYYY-MM-DD."
  argument :thread, :string, required: false, max_length: 998, description: "A Message-ID: that message and every one answering it."
  argument :message_id, :string, required: false, max_length: 998, description: "Read this one message whole."
  argument :older, :integer, required: false, minimum: 1, description: "Where the next page starts, as returned."
  effect :external
  safe_to_repeat

  def permitted? = !!agent.mail_account&.reads_sent?

  def call(account: nil, list_folders: false, folder: "INBOX", message_id: nil, older: nil, **search)
    own(account).with_mailbox do |imap|
      next { folders: Array(imap.list("", "*")).reject { it.attr.include?(:Noselect) }.map { Net::IMAP.decode_utf7(it.name) } } if list_folders
      box = folder_named(imap, folder)
      imap.examine(box)
      folder = Net::IMAP.decode_utf7(box)
      message_id ? read(imap, folder, message_id) : page(imap, folder, older, **search)
    end
  rescue Agent::MailAccount::Unreachable => problem
    raise Refusal, problem.message
  rescue Date::Error
    raise Refusal, "since and through are days, as YYYY-MM-DD."
  end

  private
    def page(imap, folder, older, from: nil, to: nil, subject: nil, since: nil, through: nil, thread: nil)
      keys = { "FROM" => from, "TO" => to, "SUBJECT" => subject }.compact_blank.flatten
      keys += [ "SINCE", Date.iso8601(since) ] if since
      keys += [ "BEFORE", Date.iso8601(through).next_day ] if through
      keys += [ "OR", "HEADER", "Message-ID", id = "<#{thread.delete("<>")}>", "OR", "HEADER", "In-Reply-To", id, "HEADER", "References", id ] if thread
      uids = imap.uid_search(keys.presence || [ "ALL" ], ("UTF-8" unless keys.join.ascii_only?)).select { older.nil? || it < older }.sort.reverse
      shown = uids.first(PAGE)
      found = shown.any? ? Array(imap.uid_fetch(shown, %w[ UID BODY.PEEK[HEADER] ])).sort_by { -it.attr["UID"] } : []
      { folder: folder, messages: found.map { summary(it.attr["UID"], Mail.new(it.attr["BODY[HEADER]"])) }, older: (shown.last if uids.size > PAGE),
        untrusted: Conversation::UNTRUSTED.strip }.compact
    end

    def summary(uid, mail)
      { uid: uid, message_id: mail.message_id, from: mail[:from]&.decoded, to: mail[:to]&.decoded, subject: mail.subject,
        date: mail.date&.iso8601, in_reply_to: mail.in_reply_to }
    end

    def read(imap, folder, message_id)
      uid = imap.uid_search([ "HEADER", "Message-ID", "<#{message_id.delete("<>")}>" ]).max or raise Refusal, "No message #{message_id} in #{folder}."
      raw = imap.uid_fetch(uid, [ "BODY.PEEK[]<0.#{FETCHED}>" ]).first.attr["BODY[]<0>"]
      mail = Mail.new(raw)
      text = mail.multipart? ? (mail.text_part || mail.html_part)&.decoded : mail.decoded
      { folder: folder, uid: uid, headers: utf8(raw.split(/\r?\n\r?\n/, 2).first).truncate(HEADERS), text: utf8(text).truncate(TEXT),
        attachments: mail.attachments.map(&:filename), untrusted: Conversation::UNTRUSTED.strip }
    end

    def utf8(text) = text.to_s.dup.force_encoding(Encoding::UTF_8).scrub
end
