require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

# An IMAP connector reads headers and nothing else (McpServer::Imap), against
# a fake server over TLS that keeps every command it was sent.
class McpServer::ImapTest < ActiveSupport::TestCase
  include AgentTestHelper

  PASSWORD = "app-password-7731".freeze
  FORBIDDEN = /\A\S+ (UID )?(SELECT|STORE|COPY|MOVE|APPEND|EXPUNGE|CLOSE|CREATE|DELETE|RENAME)\b|BODY\[(?!HEADER)|BODY\.PEEK\[(?!HEADER)|RFC822(?!\.SIZE)/i

  setup do
    @fake = FakeImap.new(password: PASSWORD)
    @saved_ssl, McpServer::Imap.ssl = McpServer::Imap.ssl, { cert_store: @fake.trust }
    @agent = create_user.agents.sole
    @connector = @agent.user.mcp_servers.create!(name: "mail", url: McpServer::Imap.address(host: "localhost", port: @fake.port, username: "maya@example.com"),
      token: PASSWORD)
  end
  teardown do
    McpServer::Imap.ssl = @saved_ssl
    @fake.stop
  end

  test "a refresh signs in and lists the two read-only tools, and a wrong password says so on the connector" do
    @connector.refresh
    assert_nil @connector.reload.refresh_error
    assert_equal %w[ list_mailboxes search_headers ], @connector.tools.pluck("name")
    assert_equal %w[ mcp__mail__list_mailboxes mcp__mail__search_headers ], @agent.reload.conversation.tools.map(&:tool_name).grep(/\Amcp__mail__/)
    assert @agent.conversation.tools.grep(Tool::Mcp).all? { it.asks.nil? }, "both run at once"
    assert_match "LOGIN maya@example.com #{PASSWORD}", @fake.commands.join("\n")

    @connector.update!(token: "wrong")
    @connector.refresh
    assert_match "mail refused its username or password", @connector.reload.refresh_error
  end

  test "folders come with their counts; a folder that can't be opened is left out" do
    result = call("list_mailboxes")
    assert_equal [ { "name" => "INBOX", "messages" => 3 }, { "name" => "Été", "messages" => 1 } ], result["mailboxes"]
    assert_read_only
  end

  test "a search examines the folder, fetches envelopes only, and gives the newest first" do
    result = call("search_headers", mailbox: "INBOX", from: "sam", since: "2026-11-01", limit: 2)

    assert_equal({ "mailbox" => "INBOX", "matched" => 3, "messages" => [
      { "uid" => 103, "from" => [ "Robin Lee <robin@example.com>" ], "to" => [ "maya@example.com" ], "subject" => "Résumé attached",
        "date" => "Tue, 10 Nov 2026 09:00:00 +0000", "message_id" => "<b@example.com>" },
      { "uid" => 102, "from" => [ "Sam <sam@example.com>" ], "to" => [ "maya@example.com" ], "cc" => [ "ada@example.com" ], "subject" => "Lunch",
        "date" => "Mon, 9 Nov 2026 10:00:00 +0000", "message_id" => "<a@example.com>" } ] }, result)
    sent = @fake.commands.join("\n")
    assert_match(/EXAMINE INBOX/, sent)
    assert_match(/UID SEARCH FROM sam SINCE 0?1-Nov-2026/, sent)
    assert_match(/UID FETCH 102[:,]103 \(?ENVELOPE\)?$/, sent)
    assert_read_only
  end

  test "the limit is at most 50, a bad day or folder is the model's error, and the call always signs out" do
    result = call("search_headers", mailbox: "INBOX", subject: "many", limit: 500)
    assert_equal [ 60, 50, 160 ], [ result["matched"], result["messages"].size, result["messages"].first["uid"] ]
    assert_match "UID FETCH 111:160", @fake.commands.join("\n")

    assert_match "YYYY-MM-DD", text(@connector.call_tool("search_headers", { mailbox: "INBOX", since: "last week" }))
    assert_match "No such folder", text(@connector.call_tool("search_headers", { mailbox: "Missing" }))
    assert_equal @fake.commands.grep(/ LOGIN /).size, @fake.commands.grep(/ LOGOUT/).size
    assert_read_only
  end

  test "only over TLS: a server whose certificate isn't trusted is never sent the password" do
    McpServer::Imap.ssl = {}
    assert_raises(McpServer::Unreachable) { @connector.call_tool("list_mailboxes", {}) }
    assert_empty @fake.commands.grep(/LOGIN/)
  end

  test "its address needs a server, a username and a password, and outside development a public server" do
    assert_equal "imaps://maya%40example.com@imap.example.com:993", McpServer::Imap.address(host: "imap.example.com", port: nil, username: "maya@example.com")
    [ [ "imaps://imap.example.com:993", PASSWORD ], [ "imaps://maya@imap.example.com:993", nil ], [ "imaps://maya@imap.example.com:70000", PASSWORD ] ].each do |url, token|
      assert_not @agent.user.mcp_servers.new(name: "other", url: url, token: token).valid?, url
    end
    original, Rails.env = Rails.env, "production"
    assert_not @agent.user.mcp_servers.new(name: "other", url: "imaps://maya@10.0.0.5:993", token: PASSWORD).valid?
  ensure
    Rails.env = original
  end

  test "outside development the server's name is resolved once and must be public, before anything is sent" do
    original, Rails.env = Rails.env, "production"
    resolver, McpServer::Address.resolver = McpServer::Address.resolver, ->(_host) { [ "10.0.0.7" ] }
    @connector.update_column(:url, "imaps://maya@mail.example.test:#{@fake.port}")
    failure = assert_raises(McpServer::Unreachable) { @connector.call_tool("list_mailboxes", {}) }
    assert_match "is on this server or its private network", failure.message
    assert_empty @fake.commands
  ensure
    Rails.env = original
    McpServer::Address.resolver = resolver
  end

  private
    def call(name, **arguments)
      result = @connector.call_tool(name, arguments)
      assert_nil result["isError"], text(result)
      result["structuredContent"]
    end

    def text(result) = result["content"].sole["text"]

    def assert_read_only
      assert_empty @fake.commands.grep(FORBIDDEN), "nothing that changes the mailbox or fetches a message's words"
    end
end

# Just enough IMAP, over TLS with its own certificate authority, to answer
# McpServer::Imap, keeping each command it is sent.
class FakeImap
  attr_reader :commands, :port, :trust

  ENVELOPES = {
    101 => '("Sun, 1 Nov 2026 08:00:00 +0000" "Old" (("Sam" NIL "sam" "example.com")) NIL NIL (("Maya" NIL "maya" "example.com")) NIL NIL NIL "<z@example.com>")',
    102 => '("Mon, 9 Nov 2026 10:00:00 +0000" "Lunch" (("Sam" NIL "sam" "example.com")) NIL NIL ((NIL NIL "maya" "example.com")) ((NIL NIL "ada" "example.com")) NIL NIL "<a@example.com>")',
    103 => '("Tue, 10 Nov 2026 09:00:00 +0000" "=?UTF-8?B?UsOpc3Vtw6kgYXR0YWNoZWQ=?=" (("Robin Lee" NIL "robin" "example.com")) NIL NIL ((NIL NIL "maya" "example.com")) NIL NIL NIL "<b@example.com>")'
  }.freeze

  def initialize(password:)
    @password, @commands = password, []
    key = OpenSSL::PKey::RSA.new(2048)
    certificate = OpenSSL::X509::Certificate.new.tap do |cert|
      cert.version, cert.serial, cert.public_key = 2, 1, key.public_key
      cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=localhost")
      cert.not_before, cert.not_after = 1.hour.ago, 1.hour.from_now
      extensions = OpenSSL::X509::ExtensionFactory.new(cert, cert)
      cert.add_extension(extensions.create_extension("subjectAltName", "DNS:localhost"))
      cert.sign(key, OpenSSL::Digest.new("SHA256"))
    end
    @trust = OpenSSL::X509::Store.new.tap { it.add_cert(certificate) }
    context = OpenSSL::SSL::SSLContext.new.tap { it.cert, it.key = certificate, key }
    @tcp = TCPServer.new("127.0.0.1", 0)
    @port = @tcp.addr[1]
    @server = OpenSSL::SSL::SSLServer.new(@tcp, context)
    @thread = Thread.new { loop { serve(@server.accept) rescue OpenSSL::SSL::SSLError } }
  end

  def stop
    @thread.kill
    @tcp.close
  end

  private
    def serve(socket)
      socket.write "* OK fake ready\r\n"
      while (line = socket.gets)
        @commands << line.chomp
        tag, command = line.chomp.split(" ", 2)
        socket.write(answer(tag, command.to_s))
        break if command.to_s.upcase.start_with?("LOGOUT")
      end
    ensure
      socket.close
    end

    def answer(tag, command)
      case command
      when /\ACAPABILITY/i then "* CAPABILITY IMAP4rev1 AUTH=PLAIN\r\n#{tag} OK done\r\n"
      when /\ALOGIN \S+ (\S+)/i then $1 == @password ? "#{tag} OK signed in\r\n" : "#{tag} NO [AUTHENTICATIONFAILED] Invalid credentials\r\n"
      when /\ALIST/i then "* LIST (\\HasNoChildren) \"/\" INBOX\r\n* LIST (\\Noselect) \"/\" Archive\r\n* LIST () \"/\" &AMk-t&AOk-\r\n#{tag} OK done\r\n"
      when /\ASTATUS (\S+)/i then "* STATUS #{$1} (MESSAGES #{$1 == "INBOX" ? 3 : 1})\r\n#{tag} OK done\r\n"
      when /\AEXAMINE INBOX/i then "* 3 EXISTS\r\n#{tag} OK [READ-ONLY] done\r\n"
      when /\AEXAMINE/i then "#{tag} NO No such folder\r\n"
      when /\AUID SEARCH SUBJECT many/i then "* SEARCH #{(101..160).to_a.join(" ")}\r\n#{tag} OK done\r\n"
      when /\AUID SEARCH/i then "* SEARCH 101 102 103\r\n#{tag} OK done\r\n"
      when /\AUID FETCH (\S+)/i
        uids = $1.split(",").flat_map { it.include?(":") ? Range.new(*it.split(":").map(&:to_i)).to_a : [ it.to_i ] }
        uids.each_with_index.map { |uid, index| "* #{index + 1} FETCH (UID #{uid} ENVELOPE #{ENVELOPES.fetch(uid, ENVELOPES[101])})\r\n" }.join + "#{tag} OK done\r\n"
      when /\ALOGOUT/i then "* BYE\r\n#{tag} OK done\r\n"
      else "#{tag} BAD unknown\r\n"
      end
    end
end
