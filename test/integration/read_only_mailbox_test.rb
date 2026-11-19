require "test_helper"
require "net/imap"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/caldav_test_helper"
require_relative "../test_helpers/email_test_helper"
require_relative "../test_helpers/passbolt_test_helper"

# A colleague's mailbox the agent took over (docs/email.md, "Read-only
# mailboxes"): its INBOX, Sent and Drafts reach the agent's thread, and nothing
# is ever sent, drafted or written there. The agent's own sending account, and
# its forced Bcc, are as they were. Net::IMAP is a stand-in that records every
# command and refuses any that writes; the fake `passbolt` command is the
# vault; WebMock the sidecar. The jobs, the mailer and the thread run for real.
class ReadOnlyMailboxTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include CaldavTestHelper
  include EmailTestHelper
  include PassboltTestHelper
  include ActiveJob::TestHelper

  SMTP = "smtp.mail.example.com"
  OLD = "imap.old.example.com"
  BCC = "records@example.org"

  # One IMAP server as Net::IMAP shows it, folder by folder. Only what reads
  # is answered: a command that would change the box raises.
  class RecordingImap
    READS = %i[ login examine responses uid_search uid_fetch disconnect ].freeze
    attr_reader :commands

    def initialize(folders, validity: 7)
      @folders, @validity, @commands = folders, validity, []
    end

    def login(*) = @commands << [ :login ]
    def disconnect = @commands << [ :disconnect ]

    def examine(name)
      @commands << [ :examine, name ]
      raise Net::IMAP::NoResponseError.new(Net::IMAP::TaggedResponse.new("A2", "NO", Net::IMAP::ResponseText.new(nil, "no such mailbox"), "")) unless @folders.key?(name)
      @current = name
    end

    def responses(name)
      @commands << [ :responses, name ]
      yield({ "UIDVALIDITY" => [ @validity ], "UIDNEXT" => [ box.keys.max.to_i + 1 ] }.fetch(name, []))
    end

    def uid_search(keys)
      @commands << [ :uid_search, @current ]
      case keys
      in [ "UID", range ] then box.keys.select { it >= range.to_i }.presence || [ box.keys.max ].compact
      in [ "SINCE", Date => day ] then box.select { |_, (_, at)| at.to_date >= day }.keys
      end
    end

    def uid_fetch(uids, part)
      @commands << [ :uid_fetch, part ]
      uids.map do |uid|
        raw, at = box.fetch(uid)
        Struct.new(:attr).new(part == "INTERNALDATE" ? { "UID" => uid, "INTERNALDATE" => Net::IMAP.encode_time(at).delete('"') } : { "UID" => uid, "BODY[]" => raw })
      end
    end

    %i[ select append store uid_store copy uid_copy move uid_move expunge uid_expunge delete create rename subscribe setflags ].each do |writes|
      define_method(writes) { |*| raise "#{writes} would change the mailbox" }
    end

    def box = @folders.fetch(@current)
    def put(folder, uid, raw) = @folders[folder][uid] = [ raw, Time.current ]
  end

  setup do
    ActionMailer::Base.deliveries.clear
    install_sidecar_settings
    install_email_settings
    install_fake_passbolt(name: "Agent mailbox", uri: SMTP)
    @original_new = Net::IMAP.method(:new)
    @servers = { "imap.agents.example" => RecordingImap.new({ "INBOX" => {} }) }
    servers = @servers
    Net::IMAP.define_singleton_method(:new) { |host, **| servers.fetch(host) }

    @alice = create_user(name: "Alice")
    @agent = @alice.agents.sole
    @conversation = create_conversation(@agent)
    @sending = @agent.create_mail_account!(address: "desk@mail.example.com", smtp_host: SMTP, vault_entry: "Agent mailbox", forced_bcc: BCC)
    @old = @agent.mail_accounts.create!(read_only: true, address: "old@example.com", imap_host: OLD, vault_entry: "Old mailbox")

    @submissions = []
    stub_request(:post, %r{\A#{SIDECAR}/v1/conversations/\d+/submissions\z}).to_return { |request|
      @submissions << JSON.parse(request.body)
      { status: 202, body: { id: @submissions.size, status: "queued" }.to_json } }
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/\d+/entries}).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
  end

  teardown do
    Net::IMAP.define_singleton_method(:new, @original_new)
    remove_fake_passbolt
    remove_email_settings
    remove_sidecar_settings
  end

  # (a), the reviewer's first.
  test "a read-only mailbox refuses send and draft: the mailer, the tool, and nothing written over IMAP" do
    assert_equal @sending, @agent.reload.mail_account, "the sending account is still the one"
    assert_equal [ @sending, @old ].sort_by(&:id), @agent.mail_accounts.sort_by(&:id)

    # The belt: were the read-only one ever the account mail would leave by.
    old = @old
    on_old = @alice.agents.find(@agent.id).tap { it.define_singleton_method(:mail_account) { old } }
    error = assert_raises(Agent::MailAccount::ReadOnly) do
      AgentMailer.message_from(on_old, to: [ "alice@example.com" ], subject: "Hi", body: "Hello.").deliver_now
    end
    assert_equal "old@example.com is read only: nothing is sent or drafted from it.", error.message

    invocation = @conversation.invocations.create!(task_id: "7", call_id: "c1", tool_name: "send_email", digest: "d",
      arguments: { "to" => [ "alice@example.com" ], "subject" => "Hi", "body" => "Hello." })
    invocation.define_singleton_method(:agent) { on_old }
    refusal = assert_raises(Tool::Refusal) { Tool::SendEmail.new(invocation).call(to: [ "alice@example.com" ], subject: "Hi", body: "Hello.") }
    assert_equal "old@example.com is read only: nothing is sent or drafted from it, so nothing was sent.", refusal.message
    assert_empty ActionMailer::Base.deliveries

    # Alone, it gives no way to send at all.
    @sending.destroy!
    with_setting(:mail, :domain, nil) do
      assert_not @agent.reload.sends_email?
      assert_not_includes @agent.conversation.definition[:tools].pluck(:name), "send_email"
    end

    # Read: EXAMINE, searches and peeks, never anything that writes.
    remove_fake_passbolt
    install_fake_passbolt(name: "Old mailbox", uri: OLD)
    imap = @servers[OLD] = RecordingImap.new({ "INBOX" => {}, "Sent" => {}, "Drafts" => {} })
    read_every_box
    %w[ INBOX Sent Drafts ].each.with_index(1) { |folder, uid| imap.put(folder, uid, raw(id: "#{folder}@example.com")) }
    read_every_box
    assert_equal 3, @submissions.size
    assert_equal [], imap.commands.map(&:first).uniq - RecordingImap::READS
    assert_equal %w[ INBOX Sent Drafts ] * 2, imap.commands.select { it.first == :examine }.map(&:last)
    assert_equal [ "BODY.PEEK[]" ], imap.commands.select { it.first == :uid_fetch }.map(&:last).uniq - [ "INTERNALDATE" ]
  end

  # (c), the reviewer's third.
  test "the sending account's forced Bcc still goes when a read-only mailbox exists, from the sending address" do
    run_call({ "to" => [ "alice@example.com" ], "subject" => "Trip", "body" => "Two nights." })

    mail = ActionMailer::Base.deliveries.sole
    assert_equal [ "desk@mail.example.com" ], mail.from
    assert_equal [ BCC ], mail.bcc
    assert_equal [ "alice@example.com", BCC ], mail.smtp_envelope_to
    assert_equal SMTP, mail.delivery_method.settings[:address]
  end

  test "it reads INBOX, Sent and Drafts, each with its own place, and its own address's mail is news" do
    remove_fake_passbolt
    install_fake_passbolt(name: "Old mailbox", uri: OLD)
    imap = @servers[OLD] = RecordingImap.new({ "INBOX" => { 1 => [ raw(id: "before@example.com"), 1.day.ago ] }, "Sent" => {}, "Drafts" => {} })
    read_every_box
    assert_empty @submissions, "what was there when it was first read is not news"
    assert_equal({ "INBOX" => 1, "Sent" => 0, "Drafts" => 0 }, @old.folders.to_h { [ it.name, it.last_uid ] })

    imap.put("INBOX", 2, raw(from: "Client <client@example.net>", to: "old@example.com", id: "in@example.net", subject: "Quote"))
    imap.put("Sent", 1, raw(from: "Old Colleague <old@example.com>", to: "client@example.net", id: "out@example.com", subject: "Re: Quote"))
    imap.put("Sent", 2, raw(from: "old@example.com", to: "old@example.com", id: "in@example.net", subject: "Quote"))
    read_every_box

    assert_equal [ "email:#{@agent.id}:in@example.net", "email:#{@agent.id}:out@example.com" ], @submissions.pluck("requestId"), "a message in two folders reaches it once"
    assert_equal %w[ followUp followUp ], @submissions.pluck("whenBusy"), "mail found in a mailbox it only reads was not sent to it, so it waits"
    inbox, sent = @submissions.pluck("content").map { words(it) }
    assert_match "In old@example.com, INBOX:", inbox
    assert_match "In old@example.com, Sent:", sent
    assert_match "Re: Quote", sent
    assert_match "a mailbox you read and never send from", sent
    assert_equal({ "INBOX" => 2, "Sent" => 2, "Drafts" => 0 }, @old.folders.reload.to_h { [ it.name, it.last_uid ] })
    assert_equal [ nil, 0, nil ], @sending.reload.values_at(:inbox_validity, :inbox_last_uid, :inbox_read_at), "the sending account's own place is its own"
  end

  test "a folder the server has not is said on the page, and the folders before it are kept" do
    remove_fake_passbolt
    install_fake_passbolt(name: "Old mailbox", uri: OLD)
    @old.update!(folder_names: "INBOX, Archive")
    @servers[OLD] = RecordingImap.new({ "INBOX" => { 1 => [ raw(id: "a@example.com"), 1.day.ago ] } })
    read_every_box

    assert_equal "#{OLD} refused the saved sign-in or the folder Archive.", @old.reload.inbox_error
    assert_equal({ "INBOX" => [ 7, 1 ], "Archive" => [ nil, 0 ] }, @old.folders.to_h { [ it.name, [ it.validity, it.last_uid ] ] })
  end

  # (b), the reviewer's second.
  test "an agent of 27 tools, send_email among them, has the same tools with a read-only mailbox and calendar, and stays within the limit" do
    install_caldav
    @old.destroy!
    @sending.destroy!
    agent = @alice.personal_workspace.agents.create!(user: @alice, name: "Desk", instructions: "Help.", model: Agent.models.first,
      tool_names: %w[ current_time remember_note list_notes forget_note ask_person make_agent join_concourse call_api_with_saved_key ], capabilities: %w[ subagents ],
      caldav_username: "agent-1", caldav_password: "app-password")
    # As the live agent: eight picked, the four every agent has, the canvas's
    # three, helpers' three, read_skill, send_email and the five calendar tools;
    # since #84 withdraw_question and #85 waiting_messages too, looked up
    # beside ask_person, #251's withdraw_card, which every agent has, and the
    # canvas's list_documents and delete_document looked up as well, so 30 own
    # and none more declared.
    agent.skills.create!(name: "handover", description: "What the colleague left.", body: "Read their Sent first.")
    before = agent.reload.own_tools.map(&:tool_name)
    assert_equal 30, before.size, before.inspect
    declared = agent.tool_count
    assert_equal 17, declared, "those in Tool::Catalog::CORE, the five calendar tools among them, with find_tools and use_tool"
    assert_includes before, "send_email"
    assert_includes before, "calendar_save_event"

    agent.mail_accounts.create!(read_only: true, address: "old@example.com", imap_host: OLD, vault_entry: "Old mailbox")
    agent.calendar_servers.create!(read_only: true, url: "https://dav.old.example.com/calendars/old/", vault_entry: "Old calendar")
    assert_equal before, agent.reload.own_tools.map(&:tool_name)
    assert_equal declared, agent.tool_count
    assert_operator agent.tool_count, :<=, Agent::TOOL_LIMIT
    assert agent.valid?
  ensure
    remove_caldav
  end

  test "every account's and calendar server's saved sign-in is kept from the browser" do
    @agent.calendar_servers.create!(read_only: true, url: "https://dav.old.example.com/calendars/old/", vault_entry: "Old calendar")
    %w[ Agent\ mailbox Old\ mailbox old\ CALENDAR ].each { assert @agent.reload.reserved_sign_in?(it), it }
    assert_not @agent.reserved_sign_in?("Bank")
  end

  private
    def read_every_box
      EmailFetchJob.perform_now
      perform_enqueued_jobs(only: MailAccountFetchJob)
    end

    def run_call(arguments, call_id: "c1")
      payload = -> { post "/agent/invocations", params: invocation_payload(@conversation, tool: "send_email", arguments:, call_id:), headers: rails_bearer, as: :json }
      with_setting(:access, :emails, [ "alice@example.com" ]) do
        payload.call
        perform_enqueued_jobs(only: InvocationCallJob)
        payload.call
      end
    end

    def raw(from: "client@example.net", to: "old@example.com", id:, subject: "Hello", body: "Hi.")
      Mail.new(from: from, to: to, subject: subject, body: body, message_id: "<#{id}>", date: Time.utc(2026, 11, 8)).to_s
    end
end
