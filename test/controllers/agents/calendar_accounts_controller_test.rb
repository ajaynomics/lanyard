require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

class Agents::CalendarAccountsControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  setup do
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: test reads the person it signed in
  end

  test "the person gives their agent its calendar account; the password is never shown, and blank keeps it" do
    with_setting(:caldav, :url, "https://caldav.example.com") do
      get agent_channels_path(@agent)
      assert_select "#calendar_account", /own account on caldav.example.com/

      patch agent_calendar_account_path(@agent), params: { agent: { caldav_username: "agent-1", caldav_password: "app-password" } }
      assert_redirected_to agent_channels_path(@agent)
      assert @agent.reload.calendar?
      follow_redirect!
      assert_select "#calendar_account input[name='agent[caldav_username]'][value='agent-1']"
      assert_select "#calendar_account input[type=password][placeholder=Saved]:not([value])"
      assert_select "#calendar_account", /reads and changes the calendars and task lists/

      patch agent_calendar_account_path(@agent), params: { agent: { caldav_username: "agent-2", caldav_password: "" } }
      assert_equal [ "agent-2", "app-password" ], @agent.reload.values_at(:caldav_username, :caldav_password)

      patch agent_calendar_account_path(@agent), params: { agent: { caldav_username: "", caldav_password: "" } }
      assert_equal [ nil, nil ], @agent.reload.values_at(:caldav_username, :caldav_password)
    end
  end

  test "without a calendar server there is no account to give" do
    get agent_channels_path(@agent)
    assert_select "#calendar_account", count: 0
    patch agent_calendar_account_path(@agent), params: { agent: { caldav_username: "agent-1", caldav_password: "x" } }
    assert_response :not_found
    assert_nil @agent.reload.caldav_username
  end
end
