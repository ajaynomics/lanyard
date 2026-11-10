require "net/imap"

# A mailbox read over IMAP, headers only (docs/connectors.md): who wrote to
# whom, when and about what, never a message's words or attachments. Rails
# answers its two tools itself, as it does Google's (McpServer::Google). The
# connector's address is imaps://<username>@<host>:<port>, and its password
# is its encrypted token.
#
# Read-only by construction: a folder is opened with EXAMINE, never SELECT,
# and only ENVELOPE is fetched. Nothing here can send STORE, COPY, MOVE,
# APPEND or EXPUNGE, or fetch a body.
class McpServer::Imap
  SCHEME = "imaps"
  PORT = 993
  TIMEOUT = 15 # seconds to connect, and for the whole of one call twice that
  LIMIT = 50
  FOLDERS = 100
  READ = { "readOnlyHint" => true }.freeze
  DATE = { "type" => "string", "pattern" => "^\\d{4}-\\d{2}-\\d{2}$" }.freeze
  TEXT = { "type" => "string", "maxLength" => 200 }.freeze

  TOOLS = [
    { "name" => "list_mailboxes", "annotations" => READ, "input_schema" => { "type" => "object", "properties" => {} },
      "description" => "The mailbox's folders, each with how many messages it holds." },
    { "name" => "search_headers", "annotations" => READ,
      "description" => "Find messages in one folder by sender, recipient, subject or date: each one's uid, from, to, cc, subject, date " \
        "and message_id, newest first. Headers only, never a message's words." + McpServer::Google::DATA,
      "input_schema" => { "type" => "object", "required" => [ "mailbox" ], "properties" => {
        "mailbox" => TEXT.merge("description" => "The folder, as list_mailboxes names it, such as INBOX."),
        "from" => TEXT.merge("description" => "Part of the sender's name or address."),
        "to" => TEXT.merge("description" => "Part of a recipient's name or address."),
        "subject" => TEXT.merge("description" => "Part of the subject."),
        "since" => DATE.merge("description" => "On or after this day, YYYY-MM-DD."),
        "before" => DATE.merge("description" => "Before this day, YYYY-MM-DD."),
        "limit" => { "type" => "integer", "minimum" => 1, "maximum" => LIMIT, "description" => "How many; #{LIMIT} at most, 20 when left out." } } } }
  ].freeze

  # Swapped in tests, which trust their own certificate authority. Empty is
  # OpenSSL's default: the server's certificate and name are checked.
  singleton_class.attr_accessor :ssl
  self.ssl = {}

  def self.imap?(url) = url.to_s.start_with?("#{SCHEME}://")
  def self.address(host:, port:, username:) = "#{SCHEME}://#{ERB::Util.url_encode(username.to_s.strip)}@#{host.to_s.strip}:#{port.presence || PORT}"

  def initialize(server)
    @server = server
    @uri = URI(server.url)
  end

  def call_tool(name, arguments)
    arguments = arguments.to_h.symbolize_keys
    content = case name
    when "list_mailboxes" then mailboxes
    when "search_headers" then search(**arguments.slice(:mailbox, :from, :to, :subject, :since, :before, :limit))
    else raise ArgumentError, "#{@server} has no tool #{name}."
    end
    { "structuredContent" => content.as_json, "content" => [ { "type" => "text", "text" => content.to_json } ] }
  rescue Net::IMAP::NoResponseError, Net::IMAP::BadResponseError, ArgumentError => refused
    { "isError" => true, "content" => [ { "type" => "text", "text" => refused.message.truncate(300) } ] }
  end

  # Signs in and out, so a refresh says whether the password works.
  def check = session { nil }

  private
    def mailboxes
      session do |imap|
        folders = Array(imap.list("", "*")).reject { it.attr.include?(:Noselect) }.first(FOLDERS)
        { mailboxes: folders.map { { name: Net::IMAP.decode_utf7(it.name), messages: imap.status(it.name, [ "MESSAGES" ])["MESSAGES"] } } }
      end
    end

    def search(mailbox:, from: nil, to: nil, subject: nil, since: nil, before: nil, limit: nil)
      criteria = { "FROM" => from, "TO" => to, "SUBJECT" => subject }.compact_blank.flat_map { |key, value| [ key, value.to_s ] }
      criteria += [ "SINCE", Date.iso8601(since) ] if since.present?
      criteria += [ "BEFORE", Date.iso8601(before) ] if before.present?
      session do |imap|
        imap.examine(Net::IMAP.encode_utf7(mailbox.to_s))
        uids = imap.uid_search(criteria.presence || [ "ALL" ], ("UTF-8" unless criteria.join.ascii_only?)).to_a
        shown = uids.last((limit || 20).to_i.clamp(1, LIMIT))
        found = shown.any? ? imap.uid_fetch(shown, "ENVELOPE").to_a : []
        { mailbox: mailbox, matched: uids.size, messages: found.map { headers(it) }.sort_by { -it[:uid] } }
      end
    rescue Date::Error
      raise ArgumentError, "since and before are days, as YYYY-MM-DD."
    end

    def headers(data)
      envelope = data.attr["ENVELOPE"]
      { uid: data.attr["UID"], from: people(envelope.from), to: people(envelope.to), cc: people(envelope.cc).presence,
        subject: words(envelope.subject), date: envelope.date, message_id: envelope.message_id }.compact
    end

    def people(addresses)
      Array(addresses).filter_map do |address|
        email = [ address.mailbox, address.host ].compact.join("@").presence or next
        address.name.present? ? "#{words(address.name)} <#{email}>" : email
      end
    end

    def words(text) = text && Mail::Encodings.value_decode(text.dup.force_encoding(Encoding::UTF_8).scrub).to_s.scrub

    # One sign-in per call, over TLS, to the address the name resolved to
    # (McpServer::Address), and always out again.
    def session
      Timeout.timeout(TIMEOUT * 2) do
        imap = Client.new(@uri.host, port: @uri.port || PORT, ssl: self.class.ssl, open_timeout: TIMEOUT,
          pinned: (McpServer::Address.public_address(@uri.host) if @server.pinned?))
        begin
          imap.login(CGI.unescape(@uri.user.to_s), @server.token.to_s)
        rescue Net::IMAP::NoResponseError => refused
          raise McpServer::Unreachable, "#{@server} refused its username or password: #{refused.message}".truncate(300)
        end
        yield imap
      ensure
        close(imap)
      end
    rescue McpServer::Address::Refused, Net::IMAP::ByeResponseError, Net::IMAP::ResponseParseError, Net::OpenTimeout, Timeout::Error,
           SocketError, SystemCallError, OpenSSL::SSL::SSLError, IOError => failure
      raise McpServer::Unreachable, "Could not reach #{@server}: #{failure.message}".truncate(300)
    end

    def close(imap)
      return unless imap
      imap.logout unless imap.disconnected?
    rescue Net::IMAP::Error, IOError, SystemCallError, OpenSSL::SSL::SSLError
      nil
    ensure
      imap.disconnect unless imap.nil? || imap.disconnected?
    end

  # Net::IMAP that connects to the address already checked, keeping the
  # name for TLS: a second lookup, which could answer differently, never happens.
  class Client < Net::IMAP
    def initialize(host, pinned: nil, **options)
      @pinned = pinned
      super(host, **options)
    end

    private
      def tcp_socket(host, port) = super(@pinned || host, port)
  end
end
