require "test_helper"
require "net/imap"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/email_test_helper"
require_relative "../test_helpers/passbolt_test_helper"
require_relative "../test_helpers/hung_imap_test_helper"

# #225: mail an agent sends through its own mail account is copied into that
# account's Sent folder over IMAP, as a mail program does, since some servers
# file nothing sent over SMTP there. Only once the server took it: a send
# refused, or whose answer never came, is not filed, or #219's look in Sent
# would find its own copy and call it sent. Never through the install's
# shared mailbox. A stand-in mail server, Net::IMAP and the fake `passbolt`
# are the only stand-ins; the mailer and the ledger run for real.
class SendEmailFilesInSentTest < ActiveSupport::TestCase
  include AgentTestHelper
  include EmailTestHelper
  include PassboltTestHelper
  include HungImapTestHelper
  include ActiveJob::TestHelper

  SMTP = "smtp.mail.example.com"
  IMAP = "imap.mail.example.com"
  MAIL = { "to" => [ "alice@example.com" ], "subject" => "Your booking", "body" => "Two nights from Friday, room 12." }.freeze

  # A mail server that takes each message and answers, keeping the bytes it
  # was given.
  class TakingServer
    cattr_accessor :taken, default: []
    def initialize(*) = nil
    def deliver!(mail) = taken << mail.encoded
  end

  class HangingServer
    cattr_accessor :taken, default: []
    def initialize(*) = nil

    def deliver!(mail)
      taken << mail.encoded
      raise Net::ReadTimeout
    end
  end

  class BusyServer
    def initialize(*) = nil
    def deliver!(*) = raise(Net::SMTPServerBusy, "421 try later")
  end

  # A mailbox as Net::IMAP shows it, with a Sent folder marked as such (RFC
  # 6154). What is appended is kept, and found by its Message-ID as a server
  # would. Every command it is sent is kept.
  class SentBox
    Listed = Net::IMAP::MailboxList
    attr_reader :commands, :appended
    attr_accessor :refuses_append

    def initialize = (@commands, @appended = [], [])
    def login(user, _password) = commands << [ :login, user ]
    def list(*) = (commands << [ :list ]) && [ Listed.new([ :Hasnochildren ], "/", "INBOX"), Listed.new([ :Hasnochildren, :Sent ], "/", "Sent Items") ]
    def examine(name) = commands << [ :examine, name ]
    def disconnect = commands << [ :disconnect ]

    def append(folder, message, flags = nil, date = nil)
      commands << [ :append, folder, flags ]
      raise Net::IMAP::NoResponseError, Net::IMAP::TaggedResponse.new("t1", "NO", Net::IMAP::ResponseText.new(nil, "over quota"), "") if refuses_append
      appended << [ folder, message, flags ]
    end

    def uid_search(keys)
      commands << [ :uid_search, keys ]
      appended.each_with_index.filter_map { |(_, raw, _), index| index + 1 if keys == [ "HEADER", "Message-ID", "<#{Mail.new(raw).message_id}>" ] }
    end
  end

  setup do
    install_sidecar_settings
    install_email_settings
    install_fake_passbolt(name: "Agent mailbox", uri: SMTP)
    TakingServer.taken, HangingServer.taken = [], []
    ActionMailer::Base.add_delivery_method :taking, TakingServer
    ActionMailer::Base.add_delivery_method :hanging, HangingServer
    ActionMailer::Base.add_delivery_method :busy, BusyServer
    AgentMailer.delivery_method = :taking
    @opened = opened = []
    @original_new = Net::IMAP.method(:new)
    @sent_box, @shared_box = SentBox.new, SentBox.new
    boxes = { IMAP => @sent_box, EmailTestHelper::MAIL[:imap_address] => @shared_box }
    Net::IMAP.define_singleton_method(:new) { |host, **| (opened << host) && boxes.fetch(host) }

    @alice = create_user(name: "Alice")
    @agent = @alice.agents.sole
    @conversation = create_conversation(@agent)
    @account = @agent.create_mail_account!(address: "desk@mail.example.com", smtp_host: SMTP, imap_host: IMAP, vault_entry: "Agent mailbox")
    stub_request(:post, %r{/v1/conversations/12/submissions}).to_return(status: 202, body: { id: 1, status: "queued" }.to_json)
  end

  teardown do
    Net::IMAP.define_singleton_method(:new, @original_new)
    AgentMailer.delivery_method = :test
    remove_fake_passbolt
    remove_email_settings
    remove_sidecar_settings
  end

  test "sent through its own account: the exact bytes the server took are appended to its Sent folder, marked read" do
    outcome = run_call("c1", MAIL)

    assert_not outcome[:isError], outcome.inspect
    sent = TakingServer.taken.sole
    assert_equal [ [ "Sent Items", sent, [ :Seen ] ] ], @sent_box.appended
    assert_equal [ IMAP ], @opened, "the install's shared mailbox is never opened"
    assert_equal [ [ :login, "maya" ], [ :list ], [ :append, "Sent Items", [ :Seen ] ], [ :disconnect ] ], @sent_box.commands
  end

  test "#219's look in Sent then finds it by its Message-ID" do
    run_call("c1", MAIL)

    dispatch = @conversation.invocations.find_by!(call_id: "c1").dispatch
    assert_equal dispatch.provider_id, Tool::SendEmail.find_dispatched(dispatch)
    assert @account.sent?(dispatch.provider_id)
  end

  test "a server that refuses it sent nothing: nothing is appended" do
    AgentMailer.delivery_method = :busy
    outcome = run_call("c1", MAIL)

    assert outcome[:isError]
    assert_empty @opened
  end

  test "a server that took it and never answered: nothing is appended, so its Sent can't vouch for it with our own copy" do
    AgentMailer.delivery_method = :hanging
    outcome = run_call("c1", MAIL)

    assert_equal [ "alice@example.com" ], outcome[:result][:unknown]
    assert_empty @sent_box.appended
    assert_not_includes @sent_box.commands.map(&:first), :append
  end

  test "the Sent folder refuses the copy: the mail still went, and the log says so without the message" do
    @sent_box.refuses_append = true
    log = capture_log { @outcome = run_call("c1", MAIL) }

    assert_not @outcome[:isError], @outcome.inspect
    assert_equal({ sent: [ "alice@example.com" ], messageId: TakingServer.taken.sole[/^Message-ID: <([^>]+)>/i, 1] }, @outcome[:result])
    assert_match(/Mail account #{@account.id}: sent mail not filed in Sent \(Net::IMAP::NoResponseError\)/, log)
    assert_no_match(/Two nights|alice@example\.com|over quota/, log)
  end

  # Its mailbox's server takes the connection and never answers: the copy
  # gives up within its time limits, and the mail, already gone, still
  # counts as sent.
  HungImapTestHelper::STOPS.each do |stop|
    test "its mailbox's server takes the connection and never answers (#{stop}): the call gives up at its limits, sent, and the log says the copy wasn't filed" do
      outcome, log = against_hung_imap(IMAP, stop, original_new: @original_new) do |server|
        @account.update!(imap_port: server.port)
        log = capture_log { @outcome = run_call("c1", MAIL) }
        [ @outcome, log ]
      end

      assert_not outcome[:isError], outcome.inspect
      assert_equal({ sent: [ "alice@example.com" ], messageId: TakingServer.taken.sole[/^Message-ID: <([^>]+)>/i, 1] }, outcome[:result])
      assert_match(/Mail account #{@account.id}: sent mail not filed in Sent \((Net::OpenTimeout|IO::TimeoutError)\)/, log)
    end
  end

  test "no Sent folder to file it in: the mail still went, and the log says so" do
    def @sent_box.list(*) = [ Net::IMAP::MailboxList.new([], "/", "INBOX") ]
    log = capture_log { @outcome = run_call("c1", MAIL) }

    assert_equal [ "alice@example.com" ], @outcome[:result][:sent]
    assert_match(/Mail account #{@account.id}: sent mail not filed in Sent \(no Sent folder\)/, log)
  end

  test "mail held for the sending hours is filed when it goes" do
    invocation = run_call("c1", MAIL) && @conversation.invocations.find_by!(call_id: "c1")
    @sent_box.appended.clear
    Tool::SendEmail.new(invocation).send_held

    assert_equal [ [ "Sent Items", TakingServer.taken.last, [ :Seen ] ] ], @sent_box.appended
  end

  test "an account with no incoming server has no Sent folder to file it in" do
    @account.update!(imap_host: nil)
    outcome = run_call("c1", MAIL)

    assert_equal [ "alice@example.com" ], outcome[:result][:sent]
    assert_empty @opened
  end

  test "mail through the install's own server is never filed: the shared mailbox is never opened" do
    @account.destroy!
    outcome = run_call("c1", MAIL)

    assert_equal [ "alice@example.com" ], outcome[:result][:sent]
    assert_empty @opened
    assert_empty @shared_box.commands
  end

  test "the app's notice that an agent needs its person goes the install's way, and is never filed" do
    AgentMailer.needs_you(@conversation, to: "alice@example.com", title: "Waiting on you", body: "Allow the email?").deliver_now

    assert_equal 1, TakingServer.taken.size
    assert_empty @opened
  end

  private
    def capture_log
      io = StringIO.new
      logger = ActiveSupport::Logger.new(io)
      Rails.logger.broadcast_to(logger)
      yield
      io.string.lines.grep(/Mail account/).join
    ensure
      Rails.logger.stop_broadcasting_to(logger)
    end

    def receive(arguments, call_id:)
      payload = invocation_payload(@conversation, tool: "send_email", arguments: arguments, call_id: call_id)
      Invocation.receive(@conversation, task_id: payload[:taskId], call_id: call_id, tool: "send_email",
        arguments: arguments, digest: payload[:digest]).deep_symbolize_keys
    end

    def run_call(call_id, arguments)
      with_setting(:access, :emails, [ "alice@example.com" ]) do
        receive(arguments, call_id: call_id)
        perform_enqueued_jobs(only: InvocationCallJob)
        receive(arguments, call_id: call_id)
      end
    end
end
