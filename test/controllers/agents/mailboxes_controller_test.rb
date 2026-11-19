require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/passbolt_test_helper"

# A colleague's mailbox and calendars the agent reads and never writes to, on
# its Channels beside its own (docs/email.md, docs/calendar.md): the
# workspace owner's alone, as its own mail account is.
class Agents::MailboxesControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include PassboltTestHelper

  MAILBOX = { address: "old@example.com", imap_host: "imap.old.example.com", imap_port: "993", vault_entry: "Old mailbox",
              folder_names: "INBOX, Sent, Drafts" }.freeze
  CALENDAR = { url: "https://dav.old.example.com/calendars/old/", vault_entry: "Old calendar" }.freeze

  setup do
    install_fake_passbolt(name: "Old mailbox", uri: "imap.old.example.com")
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: test reads the person it signed in
  end
  teardown { remove_fake_passbolt }

  test "the owner adds a read-only mailbox beside the sending account, sees it listed, and removes it" do
    @agent.create_mail_account!(address: "desk@mail.example.com", smtp_host: "smtp.mail.example.com", vault_entry: "Agent mailbox", forced_bcc: "records@example.org")
    get agent_channels_path(@agent)
    assert_select "#mail_account input[name='mail_account[address]'][value='desk@mail.example.com']"
    assert_select "#mailboxes form[action='#{agent_mailboxes_path(@agent)}'] input[name='mailbox[folder_names]'][value='INBOX, Sent, Drafts']"
    assert_select "#mailboxes input[name='mailbox[forced_bcc]']", count: 0, message: "a mailbox that never sends has no Bcc"

    post agent_mailboxes_path(@agent), params: { mailbox: MAILBOX.merge(imap_host: "") }
    assert_response :unprocessable_entity
    assert_select "#mailboxes [role=alert]", /Incoming server can't be blank/
    assert_select "#mailboxes input[name='mailbox[address]'][value='old@example.com']"

    post agent_mailboxes_path(@agent), params: { mailbox: MAILBOX }
    assert_redirected_to agent_channels_path(@agent)
    mailbox = @agent.mail_accounts.find_by!(read_only: true)
    assert_equal [ "old@example.com", "imap.old.example.com", nil, "INBOX, Sent, Drafts" ], mailbox.values_at(:address, :imap_host, :smtp_host, :folder_names)
    assert_equal "desk@mail.example.com", @agent.reload.mail_account.address, "the sending account is unchanged"
    follow_redirect!
    assert_select "#mailboxes li", /old@example.com.*imap.old.example.com.*INBOX, Sent, Drafts/m
    assert_empty passbolt_calls

    mailbox.update!(inbox_error: "imap.old.example.com refused the saved sign-in or the folder Sent.")
    get agent_channels_path(@agent)
    assert_select "#mailboxes [role=status]", /refused the saved sign-in or the folder Sent/

    delete agent_mailbox_path(@agent, mailbox)
    assert_redirected_to agent_channels_path(@agent)
    assert_equal [ "desk@mail.example.com" ], @agent.mail_accounts.reload.pluck(:address)
  end

  test "Remove there never takes the sending account" do
    sending = @agent.create_mail_account!(address: "desk@mail.example.com", smtp_host: "smtp.mail.example.com", vault_entry: "Agent mailbox")
    delete agent_mailbox_path(@agent, sending)
    assert_response :not_found
    assert @agent.reload.mail_account
  end

  test "the owner adds a read-only calendar server, sees it listed, and removes it" do
    get agent_channels_path(@agent)
    assert_select "#read_only_calendars form[action='#{agent_read_only_calendars_path(@agent)}']"

    post agent_read_only_calendars_path(@agent), params: { calendar_server: CALENDAR.merge(url: "http://dav.old.example.com/calendars/old/") }
    assert_response :unprocessable_entity
    assert_select "#read_only_calendars [role=alert]", /Server must be an https address/

    post agent_read_only_calendars_path(@agent), params: { calendar_server: CALENDAR }
    assert_redirected_to agent_channels_path(@agent)
    server = @agent.calendar_servers.find_by!(read_only: true)
    assert_nil @agent.reload.calendar_server, "it is not the agent's own calendar"
    follow_redirect!
    assert_select "#read_only_calendars li", /dav.old.example.com/

    delete agent_read_only_calendar_path(@agent, server)
    assert_redirected_to agent_channels_path(@agent)
    assert_empty @agent.calendar_servers.reload
  end

  test "another member of a shared workspace sees none of it and reaches none of it" do
    owner = User.find_by!(oidc_sub: "42") # tenancy-ok: test reads the person it signed in
    shared = Workspace.create!(name: "Household")
    shared.memberships.create!(user: owner, role: "owner")
    agent = shared.agents.create!(user: owner, name: "Shared", instructions: "Help.", model: Agent.models.first)
    mailbox = agent.mail_accounts.create!(MAILBOX.merge(read_only: true))
    calendar = agent.calendar_servers.create!(CALENDAR.merge(read_only: true))
    shared.memberships.create!(user: create_user(name: "Bob"), role: "member")
    reset!
    sign_in_via_ajent(name: "Bob", subject: "sub-bob", email: "bob@example.com")
    get workspace_path(shared)

    get agent_channels_path(agent)
    assert_response :success
    assert_select "#mailboxes", count: 0
    assert_select "#read_only_calendars", count: 0
    [ "old@example.com", "imap.old.example.com", "dav.old.example.com", "Old mailbox" ].each { assert_not_includes response.body, it }

    post agent_mailboxes_path(agent), params: { mailbox: MAILBOX.merge(address: "bob@example.net") }
    assert_response :not_found
    delete agent_mailbox_path(agent, mailbox)
    assert_response :not_found
    post agent_read_only_calendars_path(agent), params: { calendar_server: CALENDAR }
    assert_response :not_found
    delete agent_read_only_calendar_path(agent, calendar)
    assert_response :not_found
    assert_equal [ mailbox ], agent.mail_accounts.reload
    assert_equal [ calendar ], agent.calendar_servers.reload
  end

  test "not there without a password manager" do
    remove_fake_passbolt
    post agent_mailboxes_path(@agent), params: { mailbox: MAILBOX }
    assert_response :not_found
    assert_empty @agent.mail_accounts
  end
end
