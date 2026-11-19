require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/email_test_helper"
require_relative "../../test_helpers/passbolt_test_helper"

# A workspace's own mail domain (#229, docs/email.md, "A workspace's own mail
# domain"): its agents' addresses are at it, and what they and the app send
# for them goes from it, through the workspace's own server, signed in with
# the vault entry the operator named. Another workspace is unchanged.
class Workspace::MailDomainTest < ActiveSupport::TestCase
  include AgentTestHelper
  include EmailTestHelper
  include PassboltTestHelper
  include ActiveJob::TestHelper

  SERVER = "mail.field.example.net"

  setup do
    ActionMailer::Base.deliveries.clear
    install_email_settings
    install_fake_passbolt(name: "Field mail", uri: SERVER)
    @alice = create_user(name: "Alice")
    @own = @alice.agents.sole
    @field = Workspace.make(name: "Field", owner: @alice)
    @scout = @alice.start_agent("Scout", workspace: @field)
    @field.create_mail_domain!(domain: "Field.Example.NET", smtp_host: SERVER, vault_entry: "Field mail")
    @scout.reload
  end

  teardown do
    remove_fake_passbolt
    remove_email_settings
  end

  test "its agents' addresses are at its own domain; another workspace's agents' are at the install's" do
    assert_equal "scout@field.example.net", @scout.email_address
    assert_equal "#{@own.email_name}@agents.example", @own.email_address
    assert_equal "field.example.net", @field.agents_mail_domain
    assert_equal "agents.example", @alice.personal_workspace.agents_mail_domain
  end

  test "a notice that its agent needs someone comes from its domain, through its own server, signed in for that message" do
    mail = AgentMailer.needs_you(@scout.conversation, to: "alice@example.com", title: "Scout needs you", body: "Allow?").deliver_now

    assert_equal "Scout <scout@field.example.net>", mail[:from].to_s
    assert_equal({ address: SERVER, port: 587, domain: "field.example.net", user_name: "maya", password: PASSWORD, authentication: :plain,
      tls: false, ssl: false, enable_starttls: :always, enable_starttls_auto: false }, mail.delivery_method.settings.except(:location, :arguments))
    assert_includes passbolt_calls, "get resource"
  end

  test "another workspace's notice goes the install's way, as before" do
    mail = AgentMailer.needs_you(@own.conversation, to: "alice@example.com", title: "Needs you", body: "Allow?").deliver_now

    assert_equal [ "#{@own.email_name}@agents.example" ], mail.from
    assert_nil mail.delivery_method.settings[:user_name]
    assert_not_includes passbolt_calls, "get resource"
  end

  test "what its agent sends goes from its domain through its server; an agent's own mail account still goes its own way" do
    mail = AgentMailer.message_from(@scout, to: "sam@example.com", subject: "Hi", body: "Hello.").deliver_now
    assert_equal "Scout <scout@field.example.net>", mail[:from].to_s
    assert_equal SERVER, mail.delivery_method.settings[:address]

    @scout.create_mail_account!(address: "desk@mail.field.example.net", smtp_host: SERVER, vault_entry: "Field mail")
    mail = AgentMailer.message_from(@scout.reload, to: "sam@example.com", subject: "Hi", body: "Hello.").deliver_now
    assert_equal [ "desk@mail.field.example.net" ], mail.from
  end

  test "a sign-in saved for another server is never sent there, and nothing goes" do
    remove_fake_passbolt
    install_fake_passbolt(name: "Field mail", uri: "webmail.elsewhere.example")

    error = assert_raises(Workspace::MailDomain::SignInError) do
      AgentMailer.needs_you(@scout.conversation, to: "alice@example.com", title: "Scout needs you", body: "Allow?").deliver_now
    end
    assert_equal "Field mail is saved for webmail.elsewhere.example, not #{SERVER}, so it is not sent there.", error.message
    assert_empty ActionMailer::Base.deliveries
  end

  test "a notice whose server's sign-in can't be read now, the vault down, is tried again rather than lost or sent another way" do
    remove_fake_passbolt
    install_fake_passbolt(name: "Field mail", uri: SERVER, fail: true)
    clear_enqueued_jobs
    AgentMailer.needs_you(@scout.conversation, to: "alice@example.com", title: "Scout needs you", body: "Allow?").deliver_later
    job = enqueued_jobs.sole
    clear_enqueued_jobs

    ActiveJob::Base.execute(job)
    assert_empty ActionMailer::Base.deliveries
    again = enqueued_jobs.select { it["job_class"] == "MailDeliveryJob" }
    assert_equal 1, again.size, "queued again"
    assert_operator again.sole["scheduled_at"].to_time, :>, 4.minutes.from_now
  end

  test "a domain is a plain name, one workspace's, never the install's, with a server and a saved sign-in" do
    other = Workspace.make(name: "Other", owner: @alice)
    [ "field.example.net", "agents.example", "https://x.example.com", "no-dot" ].each do |domain|
      assert_not other.build_mail_domain(domain: domain, smtp_host: SERVER, vault_entry: "x").valid?, domain
    end
    assert_equal [ "Smtp host can't be blank", "Vault entry can't be blank" ],
      other.build_mail_domain(domain: "other.example.net").tap(&:valid?).errors.full_messages.grep(/Smtp|Vault/)
    assert other.build_mail_domain(domain: "other.example.net", smtp_host: SERVER, vault_entry: "x").valid?

    reading = other.build_mail_domain(domain: "other.example.net", smtp_host: SERVER, vault_entry: "x", imap_host: "imap.elsewhere.example")
    assert_equal [ "Imap host must be #{SERVER} or a server beside it, such as imap.field.example.net" ], reading.tap(&:valid?).errors.full_messages
  end

  test "an agent's address stays unique across the install, whatever its domain" do
    assert_not_equal "scout", Agent.email_name_for("Scout")
    assert_not @own.workspace.agents.create(user: @alice, name: "Other", email_name: "scout", instructions: "x", model: Agent.models.first).persisted?
  end

  test "an invitation to a workspace with its own domain comes from that domain, through its server" do
    mail = WorkspaceMailer.invitation(invite(@field)).deliver_now

    assert_equal [ "#{install_sender.local}@field.example.net" ], mail.from
    assert_equal SERVER, mail.delivery_method.settings[:address]
    assert_equal "maya", mail.delivery_method.settings[:user_name]
  end

  test "an invitation to a workspace without a domain goes the install's way, as before" do
    mail = WorkspaceMailer.invitation(invite(Workspace.make(name: "Club", owner: @alice))).deliver_now

    assert_equal [ install_sender.address ], mail.from
    assert_nil mail.delivery_method.settings[:user_name]
    assert_not_includes passbolt_calls, "get resource"
  end

  test "an invitation whose server's sign-in can't be read now is tried again, never sent the install's way" do
    remove_fake_passbolt
    install_fake_passbolt(name: "Field mail", uri: SERVER, fail: true)
    clear_enqueued_jobs
    WorkspaceMailer.invitation(invite(@field)).deliver_later
    job = enqueued_jobs.sole
    clear_enqueued_jobs

    ActiveJob::Base.execute(job)
    assert_empty ActionMailer::Base.deliveries
    assert_equal 1, enqueued_jobs.count { it["job_class"] == "MailDeliveryJob" }, "queued again"
  end

  private
    def invite(workspace) = workspace.invitations.create!(email: "newcomer@example.com", inviter: @alice)

    def install_sender = Mail::Address.new(DurableAssistants.config(:app, :mailer_from))
end
