require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/passbolt_test_helper"
require_relative "../../test_helpers/email_test_helper"

# The agent's own mail account and its forced Bcc are the workspace owner's
# alone: another member uses the agent but neither sees nor changes them.
class Agents::MailAccountsControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include PassboltTestHelper
  include EmailTestHelper

  ACCOUNT = { address: "desk@mail.example.com", display_name: "Travel desk", smtp_host: "smtp.mail.example.com", smtp_port: "587",
              vault_entry: "Agent mailbox", forced_bcc: "records@example.org" }.freeze

  setup do
    install_fake_passbolt(name: "Agent mailbox", uri: "smtp.mail.example.com")
    install_email_settings
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: test reads the person it signed in
  end
  teardown do
    remove_email_settings
    remove_fake_passbolt
  end

  test "the owner sets the account by its vault entry's name, never a password, and saving reads nothing from the vault" do
    get agent_channels_path(@agent)
    assert_select "#mail_account", /An address of .+'s own to send from/
    assert_select "#mail_account input[type=password]", count: 0
    assert_select "#mail_account input[name='mail_account[smtp_port]'][value='587']"

    patch agent_mail_account_path(@agent), params: { mail_account: ACCOUNT }
    assert_redirected_to agent_channels_path(@agent)
    assert_equal ACCOUNT.values_at(:address, :smtp_host, :vault_entry, :forced_bcc),
      @agent.reload.mail_account.values_at(:address, :smtp_host, :vault_entry, :forced_bcc)
    follow_redirect!
    assert_select "#mail_account", /sends its mail from desk@mail.example.com through smtp.mail.example.com/
    assert_select "#mail_account", /goes to records@example.org too/
    assert_empty passbolt_calls, "saving the settings reads nothing from the vault"

    patch agent_mail_account_path(@agent), params: { mail_account: { forced_bcc: "" } }
    assert_nil @agent.reload.mail_account.forced_bcc
    assert_equal "desk@mail.example.com", @agent.mail_account.address
  end

  test "the owner names the incoming server too, and the page says whether its inbox could be read" do
    patch agent_mail_account_path(@agent), params: { mail_account: ACCOUNT.merge(imap_host: "imap.mail.example.com", imap_port: "993") }
    assert_redirected_to agent_channels_path(@agent)
    assert_equal [ "imap.mail.example.com", 993 ], @agent.reload.mail_account.values_at(:imap_host, :imap_port)
    follow_redirect!
    assert_select "#mail_account input[name='mail_account[imap_host]'][value='imap.mail.example.com']"
    assert_select "#mail_account", /reads new mail to desk@mail.example.com from imap.mail.example.com/

    @agent.mail_account.update!(inbox_error: "imap.mail.example.com refused the saved sign-in or the inbox.")
    get agent_channels_path(@agent)
    assert_select "#mail_account [role=status]", /Couldn't read its inbox: imap.mail.example.com refused the saved sign-in or the inbox. It tries again every minute./
    assert_empty passbolt_calls

    patch agent_mail_account_path(@agent), params: { mail_account: { imap_host: "imap.elsewhere.example" } }
    assert_response :unprocessable_entity
    assert_select "#mail_account [role=alert]", /Incoming server must be smtp.mail.example.com or a server beside it/
    assert_equal "imap.mail.example.com", @agent.reload.mail_account.imap_host
  end

  test "a refusal keeps what was typed, its reason beside the form, and saves nothing" do
    patch agent_mail_account_path(@agent), params: { mail_account: ACCOUNT.merge(smtp_host: "user:pw@smtp.mail.example.com") }
    assert_response :unprocessable_entity
    assert_select "#mail_account [role=alert]", /Server must be a plain server name/
    assert_select "#mail_account input[name='mail_account[address]'][value='desk@mail.example.com']"
    assert_select "#mail_account input[name='mail_account[smtp_host]'][value='user:pw@smtp.mail.example.com']"
    assert_nil @agent.reload.mail_account
  end

  test "Remove takes the account away, and the agent sends as before" do
    @agent.create_mail_account!(ACCOUNT)
    get agent_channels_path(@agent)
    assert_select "#mail_account form[action='#{agent_mail_account_path(@agent)}'] input[name=_method][value=delete]"

    delete agent_mail_account_path(@agent)
    assert_redirected_to agent_channels_path(@agent)
    assert_nil @agent.reload.mail_account
  end

  test "the owner makes the account its only address with a checkbox, off by default, and turns it off again" do
    get agent_channels_path(@agent)
    assert_select "#mail_account input[type=checkbox][name='mail_account[primary]']:not([checked])"

    patch agent_mail_account_path(@agent), params: { mail_account: ACCOUNT }
    assert_not @agent.reload.mail_account.primary?, "off unless chosen"

    patch agent_mail_account_path(@agent), params: { mail_account: { primary: "1" } }
    assert_redirected_to agent_channels_path(@agent)
    assert @agent.reload.mail_account.primary?
    follow_redirect!
    assert_select "#mail_account input[type=checkbox][name='mail_account[primary]'][checked]"
    assert_select "#mail_account", /uses desk@mail.example.com alone/
    assert_not_includes response.body, @agent.email_address, "its address here is not shown while it uses its own alone"

    patch agent_mail_account_path(@agent), params: { mail_account: { primary: "0" } }
    assert_not @agent.reload.mail_account.primary?
    get agent_channels_path(@agent)
    assert_select "main", /#{Regexp.escape(@agent.email_address)}/
  end

  test "a mailbox it only reads can't be its only address" do
    mailbox = @agent.mail_accounts.new(address: "old@example.com", imap_host: "imap.example.com", vault_entry: "Old", read_only: true, primary: true)
    assert_not mailbox.valid?
    assert_includes mailbox.errors[:primary], "can't be a mailbox it only reads"
  end

  test "not there without a password manager" do
    remove_fake_passbolt
    patch agent_mail_account_path(@agent), params: { mail_account: ACCOUNT }
    assert_response :not_found
    assert_nil @agent.reload.mail_account
  end

  test "another member of a shared workspace neither sees nor changes it; its owner does" do
    owner = User.find_by!(oidc_sub: "42") # tenancy-ok: test reads the person it signed in
    shared = Workspace.create!(name: "Household")
    shared.memberships.create!(user: owner, role: "owner")
    agent = shared.agents.create!(user: owner, name: "Shared", instructions: "Help.", model: Agent.models.first)
    agent.create_mail_account!(ACCOUNT.merge(imap_host: "imap.mail.example.com", inbox_error: "imap.mail.example.com refused the saved sign-in or the inbox."))

    shared.memberships.create!(user: create_user(name: "Bob"), role: "member")
    reset!
    sign_in_via_ajent(name: "Bob", subject: "sub-bob", email: "bob@example.com")
    get workspace_path(shared)

    get agent_channels_path(agent)
    assert_response :success
    assert_select "#linked_calendar"
    assert_select "#mail_account", count: 0
    assert_not_includes response.body, "records@example.org"
    assert_not_includes response.body, "Agent mailbox"
    assert_not_includes response.body, "imap.mail.example.com"

    patch agent_mail_account_path(agent), params: { mail_account: ACCOUNT.merge(forced_bcc: "", address: "bob@example.net", imap_host: "imap.example.net") }
    assert_response :not_found
    delete agent_mail_account_path(agent)
    assert_response :not_found
    assert_equal [ "desk@mail.example.com", "records@example.org", "imap.mail.example.com" ], agent.reload.mail_account.values_at(:address, :forced_bcc, :imap_host)

    reset!
    sign_in_via_ajent
    get workspace_path(shared)
    get agent_channels_path(agent)
    assert_select "#mail_account input[name='mail_account[forced_bcc]'][value='records@example.org']"
  end
end
