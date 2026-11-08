require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/voipms_test_helper"

class Agents::PhoneNumbersControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include VoipmsTestHelper

  setup do
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: test reads the person it signed in
  end

  teardown { remove_voipms_settings }

  test "the person gives their agent a number in its Channels, sees it plainly, and clears it" do
    install_voipms_settings
    get agent_channels_path(@agent)
    assert_select "#phone_number input[type=tel][name='agent[phone_number]']:not([value])"

    patch agent_phone_number_path(@agent), params: { agent: { phone_number: "647-555-0123" } }
    assert_redirected_to agent_channels_path(@agent)
    assert_equal "6475550123", @agent.reload.phone_number
    follow_redirect!
    assert_select "#phone_number input[value='(647) 555-0123']"
    assert_select "#phone_number", /texts from this number. Each text asks you first/

    patch agent_phone_number_path(@agent), params: { agent: { phone_number: "12" } }
    follow_redirect!
    assert_select ".flash, [role=alert]", /ten-digit North American number/
    assert_equal "6475550123", @agent.reload.phone_number

    patch agent_phone_number_path(@agent), params: { agent: { phone_number: "" } }
    assert_nil @agent.reload.phone_number
  end

  test "without voip.ms there is no number to give" do
    get agent_channels_path(@agent)
    assert_select "#phone_number", count: 0
    patch agent_phone_number_path(@agent), params: { agent: { phone_number: "6475550123" } }
    assert_response :not_found
    assert_nil @agent.reload.phone_number
  end
end
