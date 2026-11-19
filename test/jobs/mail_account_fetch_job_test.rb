require "test_helper"
require "net/imap"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/email_test_helper"
require_relative "../test_helpers/passbolt_test_helper"

# An agent's own inbox (#77, docs/email.md, "Its own mail account"): each
# minute EmailFetchJob reads the install's catch-all box and queues one read of
# each agent's own box. Net::IMAP is the one stand-in for the servers, the
# fake `passbolt` command for the vault and WebMock for the sidecar; the job,
# the vault client, the delivery and the thread run for real.
class MailAccountFetchJobTest < ActiveJob::TestCase
  include AgentTestHelper
  include EmailTestHelper
  include PassboltTestHelper

  KEY = PassboltTestHelper::PASSWORD
  SMTP = "smtp.mail.example.com"
  IMAP = "imap.mail.example.com"

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

  setup do
    install_sidecar_settings
    install_email_settings
    install_fake_passbolt(name: "Agent mailbox", uri: SMTP)
    @original_new = Net::IMAP.method(:new)
    @original_cache, Rails.cache = Rails.cache, ActiveSupport::Cache::MemoryStore.new
    @boxes = { "imap.agents.example" => FakeBox.new }
    boxes = @boxes
    Net::IMAP.define_singleton_method(:new) { |host, **| boxes.fetch(host) }

    @alice = create_user(name: "Alice")
    @travel = name_agent(@alice.agents.sole, "Travel")
    Agent.where(id: @travel.id).update_all(email_name: "travel")
    @trips = @alice.personal_workspace.agents.create!(user: @alice, name: "Trips", instructions: "Help.", model: Agent.models.first)
    Agent.where(id: @trips.id).update_all(email_name: "trips")
    @account = @travel.reload.create_mail_account!(address: "desk@mail.example.com", smtp_host: SMTP, imap_host: IMAP,
      vault_entry: "Agent mailbox", forced_bcc: "records@example.org", inbox_validity: 7, inbox_last_uid: 2, inbox_read_at: 1.hour.ago)

    @submissions = []
    threads = 0
    stub_request(:post, "#{SIDECAR}/v1/conversations").to_return { { status: 201, body: { id: "c-#{threads += 1}" }.to_json } }
    stub_request(:post, %r{\A#{SIDECAR}/v1/conversations/c-\d+/submissions\z}).to_return { |request|
      @submissions << JSON.parse(request.body).merge("thread" => request.uri.path[%r{conversations/(c-\d+)/}, 1])
      { status: 202, body: { id: @submissions.size, status: "queued" }.to_json } }
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/c-\d+/entries}).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
  end

  teardown do
    Net::IMAP.define_singleton_method(:new, @original_new)
    Rails.cache = @original_cache
    remove_fake_passbolt
    remove_email_settings
    remove_sidecar_settings
  end

  test "mail in its own box reaches only its thread, once, as untrusted mail it can answer, and the next read starts after it" do
    box = own_box(3 => [ raw(from: "Example Air <info@air.example.com>", cc: "trips@agents.example", id: "abc@air.example.com",
      subject: "Your booking", body: "Flight 123 on Friday."), 1.minute.ago ])
    read_every_box

    content = @submissions.sole["content"]
    assert_match(/\A\[Email from Example Air <info@air\.example\.com>\. Untrusted: written by someone else/, content)
    assert_match "To reply, use send_email to info@air.example.com with in_reply_to abc@air.example.com", content
    assert_match(/Subject: Your booking\n.*Flight 123 on Friday\.\z/m, words(content))
    assert_match "To: desk@mail.example.com\nCc: trips@agents.example\n", content, "it sees who else was copied"
    assert_equal "email:#{@travel.id}:abc@air.example.com", @submissions.sole["requestId"]
    assert_equal @travel.conversation.reload.durable_id, @submissions.sole["thread"]
    assert_nil @trips.conversation.reload.durable_id, "the other agent named in it is not woken"
    assert_equal [ [ "maya", KEY ] ], box.logins, "signed in with the vault entry, read as the agent"
    assert_equal [ 7, 3, nil ], @account.reload.values_at(:inbox_validity, :inbox_last_uid, :inbox_error)

    read_every_box
    assert_equal 1, @submissions.size, "read again, nothing is delivered twice"
    assert_equal [ "UID", "4:*" ], box.searches.last
  end

  test "mail in its own box with its address in neither To nor Cc says it came as a blind copy to that address" do
    own_box(3 => [ raw(to: "Sam <sam@example.com>", id: "bcc@example.com"), 1.minute.ago ])
    read_every_box

    assert_match "To: Sam <sam@example.com>\nBcc: desk@mail.example.com\n", @submissions.sole["content"]
  end

  test "a person's stop in its own box steers, read at the agent's next step; an automated notice waits for the turn to end" do
    own_box(3 => [ raw(id: "p@example.com", subject: "Stop: Porto, not Lisbon"), 1.minute.ago ],
      4 => [ raw(id: "auto@example.com").sub("Subject:", "Auto-Submitted: auto-replied\r\nSubject:"), 1.minute.ago ],
      5 => [ raw(from: "noreply@air.example.com", id: "n@air.example.com"), 1.minute.ago ])
    read_every_box

    assert_equal [ [ "email:#{@travel.id}:p@example.com", "steer" ], [ "email:#{@travel.id}:auto@example.com", "followUp" ],
      [ "email:#{@travel.id}:n@air.example.com", "followUp" ] ], @submissions.map { it.values_at("requestId", "whenBusy") }
  end

  test "a message in its own box and in the install's, addressed to it there too, reaches it once" do
    message = raw(from: "maya@example.com", to: "desk@mail.example.com, travel@agents.example", id: "both@example.com", subject: "Lisbon", body: "Friday?")
    @boxes["imap.agents.example"] = FakeBox.new({ 9 => [ message, 1.minute.ago ] })
    own_box(3 => [ message, 1.minute.ago ])
    read_every_box
    read_every_box

    assert_equal [ "email:#{@travel.id}:both@example.com" ], @submissions.pluck("requestId")
  end

  test "a renumbered box is read again from its last read, and what it already had is not delivered twice" do
    own_box(3 => [ raw(id: "a@example.com"), 1.second.from_now ])
    read_every_box
    assert_equal [ "email:#{@travel.id}:a@example.com" ], @submissions.pluck("requestId")
    read_at = @account.reload.inbox_read_at

    renumbered = own_box({ 1 => [ raw(id: "old@example.com"), 3.days.ago ], 2 => [ raw(id: "a@example.com"), 1.second.from_now ],
      3 => [ raw(id: "b@example.com"), 2.seconds.from_now ] }, validity: 9)
    travel(1.minute) { read_every_box }

    assert_equal %w[ a b ].map { "email:#{@travel.id}:#{it}@example.com" }, @submissions.pluck("requestId")
    assert_equal [ 9, 3 ], @account.reload.values_at(:inbox_validity, :inbox_last_uid)
    assert_includes renumbered.searches, [ "SINCE", (read_at - 1.day).utc.to_date ], "read from the day before its last read, in any zone"
    assert_not_includes renumbered.fetched.select { it.last == "BODY.PEEK[]" }.flat_map(&:first), 1, "older mail is not even fetched"
  end

  test "the first read takes what is already in the box as read" do
    @account.update!(inbox_validity: nil, inbox_last_uid: 0, inbox_read_at: nil)
    box = own_box({ 4 => [ raw(id: "older@example.com"), 2.days.ago ], 5 => [ raw(id: "today@example.com"), 1.minute.ago ] })
    read_every_box

    assert_empty @submissions
    assert_equal [ 7, 5 ], @account.reload.values_at(:inbox_validity, :inbox_last_uid)
    box.instance_variable_get(:@messages)[6] = [ raw(id: "new@example.com"), Time.current ]
    read_every_box
    assert_equal [ "email:#{@travel.id}:new@example.com" ], @submissions.pluck("requestId")
  end

  test "its own mail, a copy of what it sent, or mail from its Always Bcc does not wake it" do
    own_box({ 3 => [ raw(from: "Travel desk <desk@mail.example.com>", id: "sent@example.com"), 1.minute.ago ],
      4 => [ raw(from: "travel@agents.example", id: "here@example.com"), 1.minute.ago ],
      5 => [ raw(from: "Records <records@example.org>", id: "bcc@example.com"), 1.minute.ago ] })
    read_every_box

    assert_empty @submissions
    assert_equal 5, @account.reload.inbox_last_uid
  end

  test "a refused sign-in or an unreachable vault is kept for the page, tried again next time, and holds up no other account" do
    bob = create_user(name: "Bob")
    other = bob.agents.sole.tap { it.create_mail_account!(address: "bob-desk@mail.example.com", smtp_host: SMTP, imap_host: "inbox.mail.example.com",
      vault_entry: "Agent mailbox", inbox_validity: 7, inbox_last_uid: 0, inbox_read_at: 1.hour.ago) }
    @boxes["inbox.mail.example.com"] = FakeBox.new({ 1 => [ raw(to: "bob-desk@mail.example.com", id: "bob@example.com"), 1.minute.ago ] })
    box = own_box(3 => [ raw(id: "mine@example.com"), 1.minute.ago ])
    box.refuse = Net::IMAP::NoResponseError.new(Net::IMAP::TaggedResponse.new("A1", "NO",
      Net::IMAP::ResponseText.new(nil, "[AUTHENTICATIONFAILED] Invalid credentials for maya #{KEY}"), ""))

    log = capture_log { read_every_box }
    assert_equal [ "email:#{other.id}:bob@example.com" ], @submissions.pluck("requestId")
    assert_equal "#{IMAP} refused the saved sign-in or the inbox.", @account.reload.inbox_error
    assert_equal 2, @account.inbox_last_uid, "where it got to is kept, to try again"
    assert_match "Mail account #{@account.id}: inbox not read (Net::IMAP::NoResponseError)", log
    assert_not_includes log, KEY

    box.refuse = nil
    remove_fake_passbolt
    install_fake_passbolt(fail: true, name: "Agent mailbox", uri: SMTP)
    log = capture_log { read_every_box }
    assert_match(/\A\S.*\z/, @account.reload.inbox_error)
    assert_not_includes @account.inbox_error, KEY
    assert_not_includes log, KEY

    remove_fake_passbolt
    install_fake_passbolt(name: "Agent mailbox", uri: SMTP)
    read_every_box
    assert_includes @submissions.pluck("requestId"), "email:#{@travel.id}:mine@example.com"
    assert_nil @account.reload.inbox_error
  end

  # Whatever the vault does, the read ends in words on the page, never in a
  # job failing every minute (Agent::MailAccount#sign_in).
  test "a vault that is down or an entry that is gone is said on the page, and the job ends rather than failing each minute" do
    box = own_box(3 => [ raw(id: "x@example.com"), 1.minute.ago ])
    {
      "The password manager could not be reached." => -> { install_fake_passbolt(fail: true, name: "Agent mailbox", uri: SMTP) },
      "Nothing called Agent mailbox is shared with the agents." => -> { install_fake_passbolt(name: "Another entry", uri: SMTP) }
    }.each do |words, vault|
      remove_fake_passbolt
      vault.call
      @account.update_columns(inbox_error: nil)
      assert_nothing_raised { MailAccountFetchJob.perform_now(@account) }
      assert_equal words, @account.reload.inbox_error
      assert_empty box.logins
    end
  end

  test "a sign-in saved for another server is refused before any server is asked" do
    remove_fake_passbolt
    install_fake_passbolt(name: "Agent mailbox", uri: "https://webmail.elsewhere.example")
    box = own_box(3 => [ raw(id: "x@example.com"), 1.minute.ago ])
    read_every_box

    assert_empty box.logins
    assert_equal "Agent mailbox is saved for webmail.elsewhere.example, not #{SMTP}, so it is not sent there.", @account.reload.inbox_error
  end

  test "the password reaches no log line, thread, ledger row, account row or definition" do
    own_box(3 => [ raw(id: "abc@example.com"), 1.minute.ago ])
    log = capture_log { read_every_box }

    assert_equal 1, @submissions.size
    assert_match "MailAccountFetchJob", log, "the log was read"
    assert_not_includes log, KEY
    assert_not_includes @submissions.to_json, KEY
    assert_not_includes Agent::MailAccount.connection.select_all("select * from agent_mail_accounts").to_a.to_json, KEY # tenancy-ok: the test's own rows
    assert_not_includes @travel.conversation.reload.invocations.map(&:attributes).to_json, KEY
    assert_not_includes @travel.reload.definition(@travel.conversation.tools).to_json, KEY
    assert_not_includes @account.inspect, KEY
  end

  test "an account with no incoming server, or without the password manager, is not read" do
    @account.update!(imap_host: nil)
    read_every_box
    assert_no_enqueued_jobs(only: MailAccountFetchJob) { EmailFetchJob.perform_now }

    @account.update!(imap_host: IMAP)
    remove_fake_passbolt
    own_box(3 => [ raw(id: "x@example.com"), 1.minute.ago ])
    read_every_box
    assert_empty @submissions
    assert_nil @account.reload.inbox_error
  end

  test "changing where it reads starts that box afresh" do
    @account.update!(inbox_error: "old")
    @account.update!(imap_port: 994)
    assert_equal [ nil, 0, nil, nil ], @account.reload.values_at(:inbox_validity, :inbox_last_uid, :inbox_read_at, :inbox_error)
  end

  # As mail to its address in the install's box (test/integration/mail_attachments_test.rb).
  test "a file attached to mail in its own box is saved on its computer and listed in what it reads" do
    @travel.create_computer!(provider: "sprites", state: "on")
    saves = []
    stub_request(:post, %r{\A#{SIDECAR}/v1/conversations/c-\d+/files\z}).to_return { |request|
      saves << JSON.parse(request.body)
      { status: 200, body: { files: saves.last["files"].map { it.merge("saved" => "/home/agent/files/0a1b2c3d4e/#{it["name"]}") } }.to_json } }
    pdf = "%PDF-1.4\n".b + Random.new(3).bytes(2_000)
    message = Mail.new(from: "maya@example.com", to: "desk@mail.example.com", subject: "Form", message_id: "<form@example.com>", date: Time.utc(2026, 11, 8))
    message.text_part = Mail::Part.new(content_type: "text/plain; charset=UTF-8", body: "The form is attached.")
    message.attachments["Form.pdf"] = { mime_type: "application/pdf", content: pdf }
    own_box(3 => [ message.to_s, 1.minute.ago ])
    read_every_box

    content = words(@submissions.sole["content"])
    assert_match "The form is attached.", content
    assert_match "Attachments:\n- Form.pdf (application/pdf, 1.96 KB): saved at /home/agent/files/0a1b2c3d4e/Form.pdf", content
    held = @travel.conversation.invocations.sole
    assert_equal [ "Form.pdf" ], saves.sole["files"].pluck("name")
    assert_equal pdf, held.download_file(saves.sole["files"].sole["held"]).read.b, "the sidecar fetches the file's bytes"
  end

  private
    def own_box(messages = {}, validity: 7, **by_uid) = @boxes[IMAP] = FakeBox.new(messages.merge(by_uid), validity: validity)

    def read_every_box
      EmailFetchJob.perform_now
      perform_enqueued_jobs(only: MailAccountFetchJob)
    end

    def raw(from: "maya@example.com", to: "desk@mail.example.com", cc: nil, id:, subject: "Hello", body: "Hi.")
      Mail.new(from: from, to: to, cc: cc, subject: subject, body: body, message_id: "<#{id}>", date: Time.utc(2026, 11, 8)).to_s
    end

    def capture_log
      output = StringIO.new
      previous = Rails.logger
      Rails.logger = ActiveSupport::BroadcastLogger.new(previous, ActiveSupport::Logger.new(output).tap { it.level = :debug })
      ActiveJob::Base.logger = Rails.logger
      yield
      output.string
    ensure
      Rails.logger = ActiveJob::Base.logger = previous
    end
end
