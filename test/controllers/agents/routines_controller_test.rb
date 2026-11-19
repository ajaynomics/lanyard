require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

class Agents::RoutinesControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: test reads the person it signed in
    @routine = @agent.routines.create!(schedule: "every weekday at 8am", prompt: "Brief me.")
  end
  teardown { remove_sidecar_settings }

  test "the agent's page lists its routines, and the person pauses, resumes and deletes one" do
    get agent_routines_path(@agent)
    assert_select ".ui-row", text: /every weekday at 8am.*Brief me\./m

    patch agent_routine_path(@agent, @routine), params: { routine: { paused: "1" } }
    assert @routine.reload.paused?
    assert_nil @routine.next_run_at
    patch agent_routine_path(@agent, @routine), params: { routine: { paused: "0" } }
    assert_not @routine.reload.paused?
    assert @routine.next_run_at.future?

    delete agent_routine_path(@agent, @routine)
    assert_redirected_to agent_routines_path(@agent)
    assert_empty @agent.routines.reload
  end

  test "a one-off shows when it runs in words, and the person cancels it before it runs" do
    @agent.update!(time_zone: "Pacific Time (US & Canada)")
    once = travel_to(Time.utc(2026, 11, 16, 12)) { @agent.routines.create!(once_at: Time.utc(2026, 11, 19, 23), prompt: "Call the plumber.") }
    travel_to Time.utc(2026, 11, 17, 12) do
      get agent_routines_path(@agent)
      assert_select "##{ActionView::RecordIdentifier.dom_id(once)}" do
        assert_select ".ui-row__label", text: /once, Thu 19 Nov at 15:00.*Call the plumber\./m
        assert_select "button", text: "Cancel"
        assert_select "button", text: "Pause", count: 0
      end

      delete agent_routine_path(@agent, once)
      assert_redirected_to agent_routines_path(@agent)
      assert_equal "Cancelled.", flash[:notice]
      assert_equal [ @routine ], @agent.routines.reload
    end
  end

  test "another person's routine is not found" do
    other = create_user(name: "Mallory").agents.sole
    routine = other.routines.create!(schedule: "every day at 8am", prompt: "x")
    delete agent_routine_path(other, routine)
    assert_response :not_found
    assert Routine.exists?(routine.id) # tenancy-ok: proves it survived
  end
end
