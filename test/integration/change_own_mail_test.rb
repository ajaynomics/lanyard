require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/email_test_helper"
require_relative "../test_helpers/imap_server_test_helper"
require_relative "../test_helpers/passbolt_test_helper"

# change_own_mail: an agent moves, deletes, marks and labels messages in its
# own mail account, named as read_own_mail gives them, with nobody asked
# first. The real Net::IMAP client talks to the recording IMAP server over
# TLS, so each test sees exactly the commands its box was sent.
class ChangeOwnMailTest < ActiveSupport::TestCase
  include AgentTestHelper
  include EmailTestHelper
  include ImapServerTestHelper
  include PassboltTestHelper
  include ActiveJob::TestHelper

  SMTP = "smtp.mail.example.com"
  IMAP = "imap.mail.example.com"

  setup do
    install_sidecar_settings
    install_email_settings
    install_fake_passbolt(name: "Agent mailbox", uri: SMTP)
    @server = start_imap(IMAP, "INBOX" => nil, "Sent Items" => :Sent, "Archive" => nil, "Deleted Items" => :Trash)
    @agent = create_user(name: "Alice").agents.sole
    @agent.workspace.update!(approval_policy: "everything")
    @conversation = create_conversation(@agent)
    @account = @agent.create_mail_account!(address: "desk@mail.example.com", smtp_host: SMTP, imap_host: IMAP, imap_port: @server.port,
      vault_entry: "Agent mailbox")
    3.times { |n| @server.deliver("INBOX", "Message-ID: <m#{n + 1}@example.com>\r\nSubject: Room #{n + 1}\r\n\r\nHello.\r\n") }
  end

  teardown do
    stop_imap
    remove_fake_passbolt
    remove_email_settings
    remove_sidecar_settings
  end

  test "marks read and unread: UID STORE +FLAGS and -FLAGS \\Seen in the folder it opened to write" do
    assert_equal({ folder: "INBOX", uids: [ 1, 2 ], done: "mark_read" }, call_tool("r1", { "action" => "mark_read", "uids" => [ 1, 2 ] }))
    call_tool("r2", { "action" => "mark_unread", "uids" => [ 2 ] })

    assert_equal [ [ "SELECT", "INBOX" ], [ "UID STORE", "1:2", "+FLAGS", "\\Seen" ],
      [ "SELECT", "INBOX" ], [ "UID STORE", "2", "-FLAGS", "\\Seen" ] ], writes
    assert_equal({ 1 => [ "\\Seen" ], 2 => [], 3 => [] }, @server.flags["INBOX"])
  end

  test "moves with MOVE where the server offers it, else COPY, STORE \\Deleted and UID EXPUNGE of those uids only" do
    @server.capabilities = "IMAP4rev1 UIDPLUS MOVE"
    assert_equal({ folder: "INBOX", uids: [ 1 ], done: "move", to: "Archive" }, call_tool("m1", { "action" => "move", "uids" => [ 1 ], "to" => "Archive" }))
    assert_equal [ [ "SELECT", "INBOX" ], [ "UID MOVE", "1", "Archive" ] ], writes

    @server.commands.clear
    @server.capabilities = "IMAP4rev1 UIDPLUS"
    @server.folders["INBOX"].last.flags << "\\Deleted" # another's, left to its own mail program
    call_tool("m2", { "action" => "move", "uids" => [ 2 ], "to" => "Archive" })
    assert_equal [ [ "SELECT", "INBOX" ], [ "UID COPY", "2", "Archive" ], [ "UID STORE", "2", "+FLAGS", "\\Deleted" ], [ "UID EXPUNGE", "2" ] ], writes
    assert_equal [ 3 ], @server.folders["INBOX"].map(&:uid)
    assert_equal [ "Room 1", "Room 2" ], @server.folders["Archive"].map { it.raw[/Subject: (.*)/, 1].strip }
  end

  test "a delete moves the mail to its own Trash with no card; mail in Trash cannot be purged" do
    @agent.workspace.update!(approval_policy: "others")
    @server.capabilities = "IMAP4rev1 UIDPLUS MOVE"
    assert_equal({ folder: "INBOX", uids: [ 1 ], done: "delete", to: "Deleted Items" }, call_tool("t1", { "action" => "delete", "uids" => [ 1 ] }))
    assert_equal [ [ "SELECT", "INBOX" ], [ "UID MOVE", "1", "Deleted Items" ] ], writes
    assert_equal [ "Room 1" ], @server.folders["Deleted Items"].map { it.raw[/Subject: (.*)/, 1].strip }

    @agent.workspace.update!(approval_policy: "everything")
    uid = @server.folders["Deleted Items"].sole.uid
    @server.commands.clear
    arguments = { "action" => "delete", "folder" => "Deleted Items", "uids" => [ uid ] }
    assert_equal "Mail in Trash stays there; empty it in the mail app.", call_tool("purge1", arguments, error: true)
    assert_empty writes
    assert_equal [ uid ], @server.folders["Deleted Items"].map(&:uid)
  end

  test "an account with no Trash folder deletes nothing" do
    @server.forget("Deleted Items")
    @server.capabilities = "IMAP4rev1 UIDPLUS MOVE"
    assert_equal "This account has no Trash folder, so nothing was deleted.", call_tool("n1", { "action" => "delete", "uids" => [ 1 ] }, error: true)
    assert_empty writes
  end

  test "deletes a message by its Message-ID to Trash, expunging that uid alone" do
    @server.capabilities = "IMAP4rev1 UIDPLUS"
    @server.folders["INBOX"].first.flags << "\\Deleted"
    call_tool("d1", { "action" => "delete", "message_id" => "<m2@example.com>" })

    assert_equal [ [ "SELECT", "INBOX" ], [ "UID COPY", "2", "Deleted Items" ], [ "UID STORE", "2", "+FLAGS", "\\Deleted" ], [ "UID EXPUNGE", "2" ] ], writes
    assert_equal [ 1, 3 ], @server.folders["INBOX"].map(&:uid)
    assert_equal "No message gone@example.com in INBOX.", call_tool("d2", { "action" => "delete", "message_id" => "gone@example.com" }, error: true)
  end

  test "a server without UIDPLUS, which could expunge only every message marked deleted, is asked to delete or copy nothing" do
    @server.capabilities = "IMAP4rev1"
    refusal = "This mail server can't remove only the chosen messages (it has no UIDPLUS), so nothing was changed."
    assert_equal refusal, call_tool("u1", { "action" => "delete", "uids" => [ 1 ] }, error: true)
    assert_equal refusal, call_tool("u2", { "action" => "move", "uids" => [ 1 ], "to" => "Archive" }, error: true)
    assert_equal [ [ "SELECT", "INBOX" ], [ "SELECT", "INBOX" ] ], writes
    assert_equal [ 1, 2, 3 ], @server.folders["INBOX"].map(&:uid)
  end

    test "labels with an IMAP keyword, or a Gmail label where the server offers X-GM-EXT-1" do
    call_tool("l1", { "action" => "label", "uids" => [ 1 ], "label" => "Travel" })
    call_tool("l2", { "action" => "unlabel", "uids" => [ 1 ], "label" => "Travel" })
    @server.capabilities = "IMAP4rev1 X-GM-EXT-1"
    call_tool("l3", { "action" => "label", "uids" => [ 3 ], "label" => "Trip plans" })

    assert_equal [ [ "SELECT", "INBOX" ], [ "UID STORE", "1", "+FLAGS", "Travel" ], [ "SELECT", "INBOX" ], [ "UID STORE", "1", "-FLAGS", "Travel" ],
      [ "SELECT", "INBOX" ], [ "UID STORE", "3", "+X-GM-LABELS", "Trip plans" ] ], writes
    assert_equal "label needs label: its name.", call_tool("l4", { "action" => "label", "uids" => [ 1 ] }, error: true)
  end

  test "only its own sending account: a mailbox it only reads, or another's, is refused before any connection" do
    assert_not Tool::Catalog.core?(Tool::ChangeOwnMail), "looked up, as read_own_mail is"
    @agent.mail_accounts.create!(address: "colleague@mail.example.com", read_only: true, imap_host: IMAP, imap_port: @server.port, vault_entry: "Agent mailbox")
    other = create_user(name: "Bob").agents.sole
    other.create_mail_account!(address: "bob-desk@mail.example.com", smtp_host: SMTP, imap_host: IMAP, imap_port: @server.port, vault_entry: "Agent mailbox")

    [ "colleague@mail.example.com", "bob-desk@mail.example.com" ].each_with_index do |address, n|
      assert_equal "#{address} is not your own mail account: you can use only desk@mail.example.com.",
        call_tool("o#{n}", { "action" => "mark_read", "uids" => [ 1 ], "account" => address }, error: true)
    end
    assert_equal 0, @server.connections
  end

  private
    def writes = @server.commands.select { WRITES.include?(it.first) }

    def call_tool(call_id, arguments, error: false)
      payload = invocation_payload(@conversation, tool: "change_own_mail", arguments: arguments, call_id: call_id)
      receive = -> { Invocation.receive(@conversation, task_id: payload[:taskId], call_id: call_id, tool: "change_own_mail",
        arguments: arguments, digest: payload[:digest]).deep_symbolize_keys }
      receive.call
      perform_enqueued_jobs(only: InvocationCallJob)
      outcome = receive.call
      assert_equal error, !!outcome[:isError], outcome.inspect
      error ? outcome.dig(:result, :error) : outcome[:result]
    end
end
