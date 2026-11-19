require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/passbolt_test_helper"

# Where the agent's own calendar lives is the workspace owner's alone, as its
# mail account is: another member uses the agent but neither sees nor changes it.
class Agents::CalendarServersControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include PassboltTestHelper

  SERVER = { url: "https://dav.mail.example.com/dav/calendars/desk/", vault_entry: "Desk calendar" }.freeze

  setup do
    install_fake_passbolt(name: "Desk calendar", uri: "https://dav.mail.example.com")
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: test reads the person it signed in
  end
  teardown { remove_fake_passbolt }

  test "the owner names the server and the vault entry, never a password, and saving reads nothing from the vault" do
    get agent_channels_path(@agent)
    assert_select "#calendar_server", /The address of its calendars on a CalDAV server of its own/
    assert_select "#calendar_server input[type=password]", count: 0

    patch agent_calendar_server_path(@agent), params: { calendar_server: SERVER }
    assert_redirected_to agent_channels_path(@agent)
    assert_equal SERVER.values, @agent.reload.calendar_server.values_at(:url, :vault_entry)
    follow_redirect!
    assert_select "#calendar_server", /keeps its calendars and task lists on dav.mail.example.com/
    assert_empty passbolt_calls
  end

  test "a refusal keeps what was typed, its reason beside the form, and saves nothing" do
    patch agent_calendar_server_path(@agent), params: { calendar_server: SERVER.merge(url: "http://dav.mail.example.com/desk/") }
    assert_response :unprocessable_entity
    assert_select "#calendar_server [role=alert]", /Server must be an https address/
    assert_select "#calendar_server input[name='calendar_server[url]'][value='http://dav.mail.example.com/desk/']"
    assert_select "#linked_calendar [role=alert]", count: 0
    assert_nil @agent.reload.calendar_server
  end

  test "Remove takes it away, and the install's account is used again" do
    @agent.create_calendar_server!(SERVER)
    delete agent_calendar_server_path(@agent)
    assert_redirected_to agent_channels_path(@agent)
    assert_nil @agent.reload.calendar_server
  end

  test "not there without a password manager" do
    remove_fake_passbolt
    patch agent_calendar_server_path(@agent), params: { calendar_server: SERVER }
    assert_response :not_found
  end

  test "another member of a shared workspace neither sees nor changes it" do
    owner = User.find_by!(oidc_sub: "42") # tenancy-ok: test reads the person it signed in
    shared = Workspace.create!(name: "Household")
    shared.memberships.create!(user: owner, role: "owner")
    agent = shared.agents.create!(user: owner, name: "Shared", instructions: "Help.", model: Agent.models.first)
    agent.create_calendar_server!(SERVER)
    shared.memberships.create!(user: create_user(name: "Bob"), role: "member")
    reset!
    sign_in_via_ajent(name: "Bob", subject: "sub-bob", email: "bob@example.com")
    get workspace_path(shared)

    get agent_channels_path(agent)
    assert_response :success
    assert_select "#calendar_server", count: 0
    assert_not_includes response.body, "dav.mail.example.com"
    assert_not_includes response.body, "Desk calendar"

    patch agent_calendar_server_path(agent), params: { calendar_server: { url: "https://dav.example.net/bob/", vault_entry: "Bob" } }
    assert_response :not_found
    delete agent_calendar_server_path(agent)
    assert_response :not_found
    assert_equal SERVER.values, agent.reload.calendar_server.values_at(:url, :vault_entry)
  end
end
