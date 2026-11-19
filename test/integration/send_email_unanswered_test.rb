require "test_helper"
require "net/imap"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/email_test_helper"
require_relative "../test_helpers/passbolt_test_helper"
require_relative "../test_helpers/hung_imap_test_helper"

# #86, mail: a mail server that takes a message and never answers. The
# message's Message-ID is chosen and recorded (Dispatch) before the server is
# asked, and only the account it went through is asked whether it holds that
# message in its Sent folder: an agent's own mail account, over IMAP. The
# install's shared mailbox is never opened to find out. A stand-in mail
# server, Net::IMAP and the fake `passbolt` are the only stand-ins; the
# ledger, the mailer and the jobs run for real.
class SendEmailUnansweredTest < ActiveSupport::TestCase
  include AgentTestHelper
  include EmailTestHelper
  include PassboltTestHelper
  include HungImapTestHelper
  include ActiveJob::TestHelper

  SMTP = "smtp.mail.example.com"
  IMAP = "imap.mail.example.com"
  MAIL = { "to" => [ "alice@example.com" ], "subject" => "Your booking", "body" => "Two nights from Friday, room 12." }.freeze

  # A mail server that takes each message whole, then sends no answer before
  # the app stops waiting, as one that hangs after DATA does.
  class HangingServer
    cattr_accessor :taken, default: []
    cattr_accessor :on_take
    def initialize(*) = nil

    def deliver!(mail)
      on_take&.call(mail)
      taken << mail
      raise Net::ReadTimeout
    end
  end

  # A mail server that turns every message away, as a busy one does.
  class BusyServer
    def initialize(*) = nil
    def deliver!(*) = raise(Net::SMTPServerBusy, "421 try later")
  end

  # A mailbox as Net::IMAP shows it: an INBOX and a Sent folder marked as
  # such (RFC 6154), whose messages are known only by their Message-IDs.
  # Every command it is sent is kept.
  class SentBox
    Listed = Net::IMAP::MailboxList
    attr_reader :commands

    def initialize(holding) = (@holding, @commands = holding, [])
    def login(user, _password) = commands << [ :login, user ]
    def list(*) = (commands << [ :list ]) && [ Listed.new([ :Hasnochildren ], "/", "INBOX"), Listed.new([ :Hasnochildren, :Sent ], "/", "Sent Items") ]
    def examine(name) = commands << [ :examine, name ]
    def disconnect = commands << [ :disconnect ]

    def uid_search(keys)
      commands << [ :uid_search, keys ]
      @holding.call.each_with_index.filter_map { |id, index| index + 1 if keys == [ "HEADER", "Message-ID", "<#{id}>" ] }
    end
  end

  setup do
    install_sidecar_settings
    install_email_settings
    install_fake_passbolt(name: "Agent mailbox", uri: SMTP)
    HangingServer.taken, HangingServer.on_take = [], nil
    ActionMailer::Base.add_delivery_method :hanging, HangingServer
    AgentMailer.delivery_method = :hanging
    @opened = opened = []
    @original_new = Net::IMAP.method(:new)
    @sent_box = SentBox.new(-> { HangingServer.taken.map(&:message_id) })
    @shared_box = SentBox.new(-> { HangingServer.taken.map(&:message_id) })
    boxes = { IMAP => @sent_box, EmailTestHelper::MAIL[:imap_address] => @shared_box }
    Net::IMAP.define_singleton_method(:new) { |host, **| (opened << host) && boxes.fetch(host) }

    @alice = create_user(name: "Alice")
    @agent = @alice.agents.sole
    @conversation = create_conversation(@agent)
    @account = @agent.create_mail_account!(address: "desk@mail.example.com", smtp_host: SMTP, imap_host: IMAP, vault_entry: "Agent mailbox")
    @told = []
    stub_request(:post, %r{/v1/conversations/12/submissions}).to_return do |request|
      @told << JSON.parse(request.body)
      { status: 202, body: { id: @told.size, status: "queued" }.to_json }
    end
  end

  teardown do
    Net::IMAP.define_singleton_method(:new, @original_new)
    AgentMailer.delivery_method = :test
    remove_fake_passbolt
    remove_email_settings
    remove_sidecar_settings
  end

  test "the server takes the message and hangs past the wait; its Sent folder holds it: the call says sent, and the agent's retry sends nothing" do
    outcome = run_call("c1", MAIL)

    taken = HangingServer.taken.sole
    assert_not outcome[:isError], outcome.inspect
    assert_equal({ sent: [ "alice@example.com" ], messageId: taken.message_id }, outcome[:result], "sent, not failed")
    assert_equal [ "sent", taken.message_id ], dispatch("c1").values_at(:state, :provider_id)

    retry_outcome = run_call("c2", MAIL)
    assert retry_outcome[:isError]
    assert_match(/This same email went to alice@example\.com at .* \(Message-ID <#{Regexp.escape(taken.message_id)}>\), so it wasn't sent again/,
      retry_outcome[:result][:error])
    assert_equal 1, HangingServer.taken.size, "sent once"
  end

  test "only the account it went through is asked, only its Sent folder, and only for that message: nothing is fetched or kept" do
    run_call("c1", MAIL)

    id = HangingServer.taken.sole.message_id
    assert_equal [ IMAP ], @opened, "the install's shared mailbox is never opened to find out"
    assert_equal [ [ :login, "maya" ], [ :list ], [ :examine, "Sent Items" ], [ :uid_search, [ "HEADER", "Message-ID", "<#{id}>" ] ], [ :disconnect ] ],
      @sent_box.commands
    assert_empty @shared_box.commands
  end

  test "its Message-ID is chosen and recorded before the server is asked" do
    recorded = nil
    HangingServer.on_take = ->(mail) { recorded = [ mail.message_id, dispatch("c1") ] }
    run_call("c1", MAIL)

    id, row = recorded
    assert_match(/\A\w{24}@mail\.example\.com\z/, id)
    assert_equal [ "pending", id, "desk@mail.example.com", "send_email" ], row&.values_at(:state, :provider_id, :sender, :tool_name)
  end

  test "sent through the install's own server, no Sent folder may be read: unknown, don't retry, and the shared mailbox is never opened" do
    @account.destroy!
    outcome = run_call("c1", MAIL)

    assert_not outcome[:isError], outcome.inspect
    assert_equal [ "alice@example.com" ], outcome[:result][:unknown]
    assert_equal HangingServer.taken.sole.message_id, outcome[:result][:messageId]
    assert_match(/\AUnknown: .*no Sent folder this app may read.*Don't send it again/, outcome[:result][:note])
    assert_empty @opened, "the install's shared mailbox is never opened to find out"
    assert_empty @shared_box.commands
    assert_equal "unknown", dispatch("c1")[:state]

    assert_match(/may have gone.*so it wasn't sent again/, run_call("c2", MAIL)[:result][:error])
    assert_equal 1, HangingServer.taken.size
  end

  test "its own account with no incoming server has no Sent folder to read either: unknown, don't retry" do
    @account.update!(imap_host: nil)
    outcome = run_call("c1", MAIL)

    assert_match(/\AUnknown: .*no Sent folder this app may read.*Don't send it again/, outcome[:result][:note])
    assert_empty @opened
  end

  test "not in its Sent folder yet: unknown and checked; once it is, the agent is told it went" do
    filed = []
    @sent_box = SentBox.new(-> { filed })
    boxes = { IMAP => @sent_box }
    Net::IMAP.define_singleton_method(:new) { |host, **| boxes.fetch(host) }

    outcome = run_call("c1", MAIL)
    id = HangingServer.taken.sole.message_id
    assert_equal [ "alice@example.com" ], outcome[:result][:unknown]
    assert_match(/can't be found in your Sent folder yet.*Don't send it again: it is being checked/, outcome[:result][:note])
    assert_match(/may have gone and is still being checked/, run_call("c2", MAIL)[:result][:error])

    filed << id
    travel(Dispatch::CHECK_AFTER + 1.second) { check_and_tell }
    assert_equal [ "sent", id ], dispatch("c1").values_at(:state, :provider_id)
    assert_match(/send_email .*went after all: its id is #{Regexp.escape(id)}\. Don't send it again/, @told.sole["content"])
    assert_equal 1, HangingServer.taken.size
  end

  test "never in its Sent folder: after the wait it is still unknown, never \"not sent\": don't retry, ask a person" do
    @sent_box = SentBox.new(-> { [] })
    boxes = { IMAP => @sent_box }
    Net::IMAP.define_singleton_method(:new) { |host, **| boxes.fetch(host) }
    run_call("c1", MAIL)
    id = HangingServer.taken.sole.message_id

    travel(Dispatch::CHECK_AFTER + 1.second) { check_and_tell }
    travel(Dispatch::NOT_LISTED_AFTER + 1.minute) { check_and_tell }
    assert_equal "unknown", dispatch("c1")[:state]
    told = @told.sole["content"]
    assert_match(/is still unknown: an hour on, the Sent folder of the account it went from lists it nowhere, so it may or may not have gone\./, told)
    assert_match(/Don't send it again; ask your person, who can check the Sent folder for Message-ID <#{Regexp.escape(id)}>, or ask the recipient/, told)
    assert_match(/may have gone.*so it wasn't sent again/, run_call("c2", MAIL)[:result][:error])
  end

  # Its mailbox's server takes the connection and never answers: the look
  # in Sent gives up within its time limits, as "couldn't ask", so the call
  # still ends, unknown, and the background check asks again. Never "not
  # sent": silence says nothing about the mail.
  HungImapTestHelper::STOPS.each do |stop|
    test "its mailbox's server takes the connection and never answers (#{stop}): the call ends in time, couldn't ask, never not sent" do
      (outcome, failed), seconds = against_hung_imap(IMAP, stop, original_new: @original_new) do |server|
        @account.update!(imap_port: server.port)
        outcome = run_call("c1", MAIL)
        [ outcome, assert_raises(Dispatch::LookupFailed) { Tool::SendEmail.find_dispatched(@conversation.invocations.find_by!(call_id: "c1").dispatch) } ]
      end

      assert_operator seconds, :<, 5, "two looks, each within a second's limits"
      assert_match(/\ACould not reach #{IMAP} on port \d+ \((OpenTimeout|TimeoutError)\)\.\z/, failed.message)
      assert_equal [ "alice@example.com" ], outcome[:result][:unknown]
      assert_match(/Don't send it again: it is being checked/, outcome[:result][:note])
      assert_equal "checking", dispatch("c1")[:state]
    end
  end

  test "a server that refuses it outright sent nothing: the call fails, and the same words may go again" do
    ActionMailer::Base.add_delivery_method :busy, BusyServer
    AgentMailer.delivery_method = :busy
    outcome = run_call("c1", MAIL)

    assert outcome[:isError]
    assert_equal "not_sent", dispatch("c1")[:state]
    assert_empty @opened
  end

  private
    def dispatch(call_id) = @conversation.invocations.find_by!(call_id: call_id).dispatch&.attributes&.symbolize_keys

    def check_and_tell
      perform_enqueued_jobs(only: DispatchCheckJob, at: Time.current)
      perform_enqueued_jobs(only: DispatchReportJob)
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
