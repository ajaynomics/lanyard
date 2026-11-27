require "test_helper"
require "net/imap"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/email_test_helper"
require_relative "../test_helpers/passbolt_test_helper"

# #618: an agent with its own mail account saves a draft in that account's
# Drafts folder over IMAP, for the person to review and send from their own
# mail program. Saving reaches nobody, so nothing asks first and nothing is
# sent. A stand-in mailbox, Net::IMAP and the fake `passbolt` are the only
# stand-ins; the ledger and the mailer run for real.
class SaveDraftTest < ActiveSupport::TestCase
  include AgentTestHelper
  include EmailTestHelper
  include PassboltTestHelper
  include ActiveJob::TestHelper

  SMTP = "smtp.mail.example.com"
  IMAP = "imap.mail.example.com"
  DRAFT = { "to" => [ "hotel@example.net" ], "cc" => [ "bob@example.com" ], "subject" => "Re: Your booking",
    "body" => "Two nights from Friday, please.", "in_reply_to" => "abc@hotel.example.net" }.freeze

  # A mailbox as Net::IMAP shows it, with a Drafts folder marked as such (RFC
  # 6154). What is appended is kept with its flags.
  class DraftsBox
    Listed = Net::IMAP::MailboxList
    attr_reader :appended
    attr_accessor :folders

    def initialize = (@appended, @folders = [], [ Listed.new([ :Hasnochildren ], "/", "INBOX"), Listed.new([ :Hasnochildren, :Drafts ], "/", "Brouillons") ])
    def login(*) = nil
    def list(*) = folders
    def disconnect = nil
    def append(folder, message, flags = nil, _date = nil) = appended << [ folder, message, flags ]
  end

  setup do
    ActionMailer::Base.deliveries.clear
    install_sidecar_settings
    install_email_settings
    install_fake_passbolt(name: "Agent mailbox", uri: SMTP)
    @original_new = Net::IMAP.method(:new)
    box = @box = DraftsBox.new
    Net::IMAP.define_singleton_method(:new) { |host, **| host == IMAP ? box : raise(Errno::ECONNREFUSED) }

    @alice = create_user(name: "Alice")
    @agent = @alice.agents.sole
    @conversation = create_conversation(@agent)
    @account = @agent.create_mail_account!(address: "desk@mail.example.com", display_name: "Travel desk", smtp_host: SMTP,
      imap_host: IMAP, vault_entry: "Agent mailbox", forced_bcc: "records@example.org")
  end

  teardown do
    Net::IMAP.define_singleton_method(:new, @original_new)
    remove_fake_passbolt
    remove_email_settings
    remove_sidecar_settings
  end

  test "a draft lands in the folder marked Drafts, flagged as one, from its own address and threaded to the mail it answers; nothing is sent" do
    outcome = run_call("d1", DRAFT)

    assert_not outcome[:isError], outcome.inspect
    folder, raw, flags = @box.appended.sole
    assert_equal "Brouillons", folder
    assert_includes flags, :Draft
    draft = Mail.new(raw)
    assert_equal "Travel desk <desk@mail.example.com>", draft[:from].to_s
    assert_equal [ "hotel@example.net" ], draft.to
    assert_equal [ "bob@example.com" ], draft.cc
    assert_equal "Re: Your booking", draft.subject
    assert_equal "abc@hotel.example.net", draft.in_reply_to
    assert_equal "abc@hotel.example.net", draft.references
    assert_includes draft.text_part.decoded, "Two nights from Friday, please."
    assert_nil draft.bcc
    assert_empty ActionMailer::Base.deliveries, "saving sends nothing"
    assert_nil @conversation.invocations.find_by!(call_id: "d1").approval, "and asks no one first"
  end

  test "a server that marks no Drafts folder has the one named Drafts used; one with neither is told so" do
    @box.folders = [ DraftsBox::Listed.new([], "/", "INBOX"), DraftsBox::Listed.new([], "/", "[Gmail]/Drafts") ]
    run_call("d1", DRAFT)
    assert_equal "[Gmail]/Drafts", @box.appended.sole.first

    @box.folders = [ DraftsBox::Listed.new([], "/", "INBOX") ]
    outcome = run_call("d2", DRAFT)
    assert outcome[:isError], outcome.inspect
    assert_equal "The draft wasn't saved: imap.mail.example.com has no Drafts folder.", outcome.dig(:result, :error)
  end

  test "a server refusing the draft is told in our words, never its own" do
    def @box.append(*) = raise(Net::IMAP::NoResponseError, Net::IMAP::TaggedResponse.new("t1", "NO", Net::IMAP::ResponseText.new(nil, "over quota"), ""))
    outcome = run_call("d1", DRAFT)

    assert outcome[:isError], outcome.inspect
    assert_equal "The draft wasn't saved: imap.mail.example.com refused the saved sign-in or the draft.", outcome.dig(:result, :error)
  end

  test "it is offered only to an agent whose own account it can read, never for a mailbox it only reads" do
    assert @conversation.reload.tool("save_draft")

    @account.update!(imap_host: nil)
    assert_nil @conversation.reload.tool("save_draft"), "no incoming server"

    @account.destroy!
    @agent.mail_accounts.create!(address: "colleague@mail.example.com", read_only: true, imap_host: IMAP, vault_entry: "Agent mailbox")
    assert_nil @conversation.reload.tool("save_draft"), "a mailbox it only reads is never drafted in"
  end

  test "a mailbox it only reads is refused: the call is turned away and the mailbox itself writes nothing" do
    @account.destroy!
    colleague = @agent.mail_accounts.create!(address: "colleague@mail.example.com", read_only: true, imap_host: IMAP, vault_entry: "Agent mailbox")

    outcome = run_call("d1", DRAFT)
    assert outcome[:isError], outcome.inspect
    assert_equal "save_draft is not one of this agent's tools.", outcome.dig(:result, :error)

    error = assert_raises(Agent::MailAccount::ReadOnly) { colleague.save_draft("Subject: Hello\r\n\r\nHi") }
    assert_equal "colleague@mail.example.com is read only: nothing is sent or drafted from it.", error.message
    assert_empty @box.appended
    assert_empty ActionMailer::Base.deliveries
  end

  private
    def receive(arguments, call_id:)
      payload = invocation_payload(@conversation, tool: "save_draft", arguments: arguments, call_id: call_id)
      Invocation.receive(@conversation, task_id: payload[:taskId], call_id: call_id, tool: "save_draft",
        arguments: arguments, digest: payload[:digest]).deep_symbolize_keys
    end

    def run_call(call_id, arguments)
      receive(arguments, call_id: call_id)
      perform_enqueued_jobs(only: InvocationCallJob)
      receive(arguments, call_id: call_id)
    end
end
