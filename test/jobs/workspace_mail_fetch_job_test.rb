require "test_helper"
require "net/imap"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/email_test_helper"
require_relative "../test_helpers/passbolt_test_helper"

# A workspace's own mail domain has its own catch-all box (#229): each minute
# EmailFetchJob queues one read of it, signed in with the workspace's saved
# sign-in, and its new mail goes to Action Mailbox, which routes it as it does
# the install's (AgentsMailbox). Mail already there when it is first read is
# not news. Net::IMAP and the fake `passbolt` command are the stand-ins.
class WorkspaceMailFetchJobTest < ActiveJob::TestCase
  include AgentTestHelper
  include EmailTestHelper
  include PassboltTestHelper

  # A mailbox as Net::IMAP shows it: messages by UID, each with the time the
  # server took it (INTERNALDATE), its UIDVALIDITY and UIDNEXT.
  class FakeBox
    attr_reader :searches, :logins, :fetched
    attr_accessor :refuse

    def initialize(messages = {}, validity: 7)
      @messages, @validity, @searches, @logins, @fetched = messages, validity, [], [], []
    end

    def login(user, password)
      @logins << [ user, password ]
      raise refuse if refuse
    end

    def examine(_mailbox) = nil
    def disconnect = nil

    def responses(name)
      yield({ "UIDVALIDITY" => [ @validity ], "UIDNEXT" => [ @messages.keys.max.to_i + 1 ] }.fetch(name, []))
    end

    # "n:*" always includes the newest message, even below n, as IMAP does.
    def uid_search(keys)
      @searches << keys
      case keys
      in [ "UID", range ]
        from = range.to_i
        @messages.keys.select { it >= from }.presence || [ @messages.keys.max ].compact
      in [ "SINCE", Date => day ]
        @messages.select { |_, (_, at)| at.to_date >= day }.keys
      end
    end

    def uid_fetch(uids, part)
      @fetched << [ uids, part ]
      uids.map do |uid|
        raw, at = @messages.fetch(uid)
        Struct.new(:attr).new(part == "INTERNALDATE" ? { "UID" => uid, "INTERNALDATE" => Net::IMAP.encode_time(at).delete('"') } : { "UID" => uid, "BODY[]" => raw })
      end
    end
  end

  SMTP = "mail.field.example.net"
  SHARED = "This catch-all is also an agent's own mailbox, so it is not read: that agent would see every other agent's mail. " \
    "Give the domain a catch-all mailbox no agent owns (docs/email.md).".freeze

  setup do
    install_email_settings
    install_fake_passbolt(name: "Field mail", uri: SMTP)
    @original_new = Net::IMAP.method(:new)
    @boxes = { "imap.agents.example" => FakeBox.new, SMTP => FakeBox.new({ 4 => [ raw_mail("old"), 1.day.ago ] }, validity: 3) }
    boxes = @boxes
    Net::IMAP.define_singleton_method(:new) { |host, **| boxes.fetch(host) }
    @field = Workspace.create!(name: "Field")
    @domain = @field.create_mail_domain!(domain: "field.example.net", smtp_host: SMTP, imap_host: SMTP, vault_entry: "Field mail")
  end

  teardown do
    Net::IMAP.define_singleton_method(:new, @original_new)
    remove_fake_passbolt
    remove_email_settings
  end

  test "each minute its box is queued for a read of its own; a domain without one is not" do
    Workspace.create!(name: "Quiet").create_mail_domain!(domain: "quiet.example.net", smtp_host: "mail.quiet.example.net", vault_entry: "Quiet mail")

    assert_enqueued_with(job: WorkspaceMailFetchJob, args: [ @domain ]) { EmailFetchJob.perform_now }
    assert_equal 1, enqueued_jobs.count { it["job_class"] == "WorkspaceMailFetchJob" }
  end

  test "its box is read with its saved sign-in, from the first read on: what was already there is not news" do
    assert_no_difference(-> { ActionMailbox::InboundEmail.count }) { WorkspaceMailFetchJob.perform_now(@domain) }
    assert_equal [ [ "maya", PassboltTestHelper::PASSWORD ] ], @boxes[SMTP].logins
    assert_equal [ 3, 4 ], @domain.reload.values_at(:inbox_validity, :inbox_last_uid)

    @boxes[SMTP] = FakeBox.new({ 4 => [ raw_mail("old"), 1.day.ago ], 5 => [ raw_mail("new"), Time.current ] }, validity: 3)
    assert_difference(-> { ActionMailbox::InboundEmail.count }, 1) { WorkspaceMailFetchJob.perform_now(@domain) }
    assert_equal "<new@example.com>", "<#{ActionMailbox::InboundEmail.last.message_id}>"
    assert_nil @domain.reload.inbox_error
  end

  test "a sign-in saved for another server is not sent to its box; why is kept, in our words" do
    remove_fake_passbolt
    install_fake_passbolt(name: "Field mail", uri: "webmail.elsewhere.example")

    WorkspaceMailFetchJob.perform_now(@domain)
    assert_empty @boxes[SMTP].logins
    assert_equal "Field mail is saved for webmail.elsewhere.example, not #{SMTP}, so it is not sent there.", @domain.reload.inbox_error
  end

  # One mailbox read by two readers, the catch-all and an agent's own inbox,
  # would hand that agent every other agent's mail. The same box is the same
  # incoming server and user name, whatever their case or spaces.
  test "a catch-all that is also an agent's own mailbox is not read; why is kept, and the log names only the workspace" do
    catch_all_signs_in_as "desk@field.example.net"
    desk_account address: "desk@field.example.net"

    log = capture_log { assert_no_difference(-> { ActionMailbox::InboundEmail.count }) { WorkspaceMailFetchJob.perform_now(@domain) } }
    assert_empty @boxes[SMTP].logins
    assert_equal SHARED, @domain.reload.inbox_error
    assert_includes log, "Workspace #{@field.id}'s mail domain: catch-all not read"
    assert_not_includes log, "desk@"
  end

  test "an agent's mailbox whose own saved sign-in is the catch-all's user name is the same box, whatever its address" do
    desk_account address: "frontdesk@field.example.net", vault_entry: "Field mail"

    WorkspaceMailFetchJob.perform_now(@domain)
    assert_empty @boxes[SMTP].logins
    assert_equal SHARED, @domain.reload.inbox_error
  end

  test "case and spaces in the user name or server still make the same box" do
    catch_all_signs_in_as "  Desk@Field.Example.NET "
    desk_account(address: "desk@field.example.net").update_column(:imap_host, SMTP.upcase)

    WorkspaceMailFetchJob.perform_now(@domain)
    assert_empty @boxes[SMTP].logins
    assert_equal SHARED, @domain.reload.inbox_error
  end

  test "an agent of another workspace on the same box is refused too: an address is the install's" do
    catch_all_signs_in_as "desk@field.example.net"
    desk_account address: "desk@field.example.net", agent: create_user(name: "Alice").agents.sole

    WorkspaceMailFetchJob.perform_now(@domain)
    assert_empty @boxes[SMTP].logins
    assert_equal SHARED, @domain.reload.inbox_error
  end

  test "an agent's own mailbox elsewhere, or another user name on the same server, is another box: the catch-all is read" do
    catch_all_signs_in_as "inbox@field.example.net"
    desk_account address: "desk@field.example.net"
    desk_account address: "inbox@other.example.net", imap_host: "imap.other.example.net"

    WorkspaceMailFetchJob.perform_now(@domain)
    assert_equal [ [ "inbox@field.example.net", PassboltTestHelper::PASSWORD ] ], @boxes[SMTP].logins
    assert_nil @domain.reload.inbox_error
  end

  # One agent in the workspace: the provider's catch-all may be its own
  # mailbox, read by its own inbox alone, while the domain only sends.
  test "a domain that only sends reads no catch-all, so an agent's own mailbox may be the provider's catch-all" do
    @domain.update!(imap_host: nil)
    account = desk_account(address: "desk@field.example.net", vault_entry: "Field mail")

    EmailFetchJob.perform_now
    assert_enqueued_with(job: MailAccountFetchJob, args: [ account ])
    assert_equal 0, enqueued_jobs.count { it["job_class"] == "WorkspaceMailFetchJob" }
    assert_nil @domain.fetch_catch_all
    assert_empty @boxes[SMTP].logins
    assert_nil @domain.reload.inbox_error
    assert_equal "scout@field.example.net", field_agent.reload.email_address
    assert_equal SMTP, @domain.delivery_options[:address]
  end

  private
    def catch_all_signs_in_as(user_name)
      remove_fake_passbolt
      install_fake_passbolt(name: "Field mail", uri: SMTP, username: user_name)
    end

    # "Desk mail" is in no vault here, so only the address can match, unless a test names the catch-all's entry.
    def desk_account(address:, vault_entry: "Desk mail", imap_host: SMTP, agent: field_agent, **sending)
      sending = { smtp_host: SMTP } if sending.empty? && agent.mail_accounts.none?
      agent.mail_accounts.create!(address:, imap_host:, vault_entry:, read_only: sending.empty?, **sending)
    end

    def field_agent = @field_agent ||= create_user(name: "Olive").start_agent("Scout", workspace: @field)

    def capture_log
      io = StringIO.new
      logger = ActiveSupport::Logger.new(io)
      Rails.logger.broadcast_to(logger)
      yield
      io.string
    ensure
      Rails.logger.stop_broadcasting_to(logger)
    end

    def raw_mail(id) = Mail.new(from: "a@example.com", to: "scout@field.example.net", subject: id, body: id, message_id: "<#{id}@example.com>").to_s
end
