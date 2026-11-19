require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/passbolt_test_helper"

class Agents::LinkedCalendarsControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include PassboltTestHelper

  setup do
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: test reads the person it signed in
  end
  teardown { remove_fake_passbolt }

  test "the person links one calendar by its server, its address and its saved sign-in's name, never a password" do
    install_fake_passbolt(name: "Family calendar", uri: "https://caldav.example.com")
    get agent_channels_path(@agent)
    assert_select "#linked_calendar", /One calendar from another account/
    assert_select "#linked_calendar input[type=password]", count: 0

    patch agent_linked_calendar_path(@agent), params: { agent: { linked_calendar_server: "https://caldav.example.com",
      linked_calendar: "/123/calendars/family/", linked_calendar_entry: "Family calendar" } }
    assert_redirected_to agent_channels_path(@agent)
    assert @agent.reload.linked_calendar?
    follow_redirect!
    assert_select "#linked_calendar input[name='agent[linked_calendar]'][value='/123/calendars/family/']"
    assert_select "#linked_calendar", /reads and changes this one calendar/
    assert_empty passbolt_calls, "saving the settings reads nothing from the vault"

    patch agent_linked_calendar_path(@agent), params: { agent: { linked_calendar: "https://elsewhere.example/family/" } }
    assert_response :unprocessable_entity
    assert_equal "/123/calendars/family/", @agent.reload.linked_calendar
  end

  test "one form with a button sends all three, and a refusal keeps what was typed, its reason beside the form" do
    install_fake_passbolt(name: "Family calendar", uri: "https://caldav.example.com")
    get agent_channels_path(@agent)
    assert_select "#linked_calendar form[data-controller~=autosave]", count: 0
    assert_select "#linked_calendar form input[type=submit][value='Link calendar']"

    patch agent_linked_calendar_path(@agent), params: { agent: { linked_calendar_server: "https://caldav.example.com",
      linked_calendar: "https://elsewhere.example/family/", linked_calendar_entry: "Family calendar" } }
    assert_response :unprocessable_entity
    assert_select "#linked_calendar [role=alert]", /must be on the server named/
    assert_select "#linked_calendar input[name='agent[linked_calendar_server]'][value='https://caldav.example.com']"
    assert_select "#linked_calendar input[name='agent[linked_calendar]'][value='https://elsewhere.example/family/']"
    assert_select "#linked_calendar input[name='agent[linked_calendar_entry]'][value='Family calendar']"
    assert_nil @agent.reload.linked_calendar_server
  end

  test "Unlink clears all three at once" do
    install_fake_passbolt(name: "Family calendar", uri: "https://caldav.example.com")
    @agent.update!(linked_calendar_server: "https://caldav.example.com", linked_calendar: "/123/calendars/family/", linked_calendar_entry: "Family calendar")
    get agent_channels_path(@agent)
    assert_select "#linked_calendar form[action='#{agent_linked_calendar_path(@agent)}'] input[name=_method][value=delete]"
    assert_select "#linked_calendar", /Unlink to stop/

    delete agent_linked_calendar_path(@agent)
    assert_redirected_to agent_channels_path(@agent)
    assert_equal [ nil, nil, nil ], @agent.reload.values_at(:linked_calendar_server, :linked_calendar, :linked_calendar_entry)
    follow_redirect!
    assert_select "#linked_calendar button", text: "Unlink", count: 0
  end

  test "a . or .. in the calendar or the server's path is refused as typed, before it can be resolved away" do
    install_fake_passbolt(name: "Family calendar", uri: "https://caldav.example.com")
    [ [ "https://caldav.example.com", "/123/calendars/family/../../" ], [ "https://caldav.example.com", "/123/calendars/./family/" ],
      [ "https://caldav.example.com", "https://caldav.example.com/123/calendars/family/%2E%2E/" ],
      [ "https://caldav.example.com/123/calendars/x/..", "family" ] ].each do |server, calendar|
      patch agent_linked_calendar_path(@agent), params: { agent: { linked_calendar_server: server, linked_calendar: calendar, linked_calendar_entry: "Family calendar" } }
      assert_response :unprocessable_entity, [ server, calendar ].inspect
      assert_select "#linked_calendar [role=alert]", /\. or \.\./
      assert_nil @agent.reload.linked_calendar
    end
  end

  test "with only the password manager set up, Channels is in the menu and the page is not empty" do
    install_fake_passbolt(name: "Family calendar", uri: "https://caldav.example.com")
    with_setting(:concourse, :origin, nil) do
      get agent_path(@agent)
      assert_select "a[href='#{agent_channels_path(@agent)}']"
      get agent_channels_path(@agent)
      assert_select "#linked_calendar"
      assert_no_match "no channels set up", response.body
    end
  end

  test "without the password manager there is nothing to link" do
    get agent_channels_path(@agent)
    assert_select "#linked_calendar", count: 0
    patch agent_linked_calendar_path(@agent), params: { agent: { linked_calendar_server: "https://caldav.example.com" } }
    assert_response :not_found
    delete agent_linked_calendar_path(@agent)
    assert_response :not_found
    assert_nil @agent.reload.linked_calendar_server
  end
end
