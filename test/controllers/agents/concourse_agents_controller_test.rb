require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/concourse_test_helper"

# Disconnecting from Concourse, and an agent connected before joining existed.
class Agents::ConcourseAgentsControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include ConcourseTestHelper

  setup do
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: test reads the person it signed in
  end

  test "Disconnect asks first, has Concourse retire the agent, then forgets it" do
    concourse = stub_fake_concourse(admit_on_join: true)
    post agent_concourse_join_path(@agent)
    get URI(Net::HTTP.get_response(URI(response.location))["location"]).then { "#{it.path}?#{it.query}" }
    follow_redirect!
    assert_select "#concourse form[action='#{agent_concourse_agent_path(@agent, @agent.concourse_agent)}'] button[data-turbo-confirm=?]",
      "Disconnect Assistant from Concourse? Its address stops working; joining again gives it a new one."

    delete agent_concourse_agent_path(@agent, @agent.concourse_agent)

    assert_redirected_to agent_channels_path(@agent)
    assert_equal "Assistant is no longer on Concourse.", flash[:notice]
    assert_equal [ "acme/assistant" ], concourse.revocations
    assert_nil @agent.reload.concourse_agent
  end

  test "a Disconnect Concourse does not take keeps the credential, says why, and can be tried again" do
    create_concourse_agent(@agent, checked_at: Time.current)
    stub_concourse_token
    revoke = stub_request(:post, "#{ORIGIN}/connect/revoke").with(headers: { "Authorization" => "Bearer #{ACCESS_TOKEN}" }).to_return(status: 500).then.to_return(status: 204)

    delete agent_concourse_agent_path(@agent, @agent.concourse_agent)

    assert_equal "Assistant is still on Concourse: Concourse did not take acme/assistant off; it answered 500. Try again.", flash[:alert]
    assert_equal "secret-1", @agent.reload.concourse_agent.client_secret

    delete agent_concourse_agent_path(@agent, @agent.concourse_agent)

    assert_requested revoke, times: 2
    assert_nil @agent.reload.concourse_agent
  end

  test "an agent connected with pasted credentials shows as connected, and is not asked again" do
    create_concourse_agent(@agent, checked_at: 2.minutes.ago)

    get agent_channels_path(@agent)

    assert_select "#concourse", /Connected/
    assert_select "#concourse .channel__address", "acme/assistant"
    assert_select "#concourse button", "Disconnect"
    assert_not_requested :any, /concourse\.example|id\.example/
    assert_includes @agent.tools([]), Tool::ConcourseSend
  end

  test "an agent whose credentials Concourse no longer accepts says so, and offers to join again" do
    create_concourse_agent(@agent, status: "disconnected", checked_at: 1.hour.ago)

    get agent_channels_path(@agent)

    assert_select "#concourse", /Disconnected/
    assert_select "#concourse", /Concourse no longer accepts Assistant's credentials\./
    assert_select "#concourse button", "Join again"
  end

  test "someone else's agent is not found" do
    other = create_user(name: "Sam").agents.sole
    create_concourse_agent(other)

    delete agent_concourse_agent_path(other, other.concourse_agent)
    assert_response :not_found
    delete agent_concourse_agent_path(@agent, other.concourse_agent)
    assert_response :not_found, "another's identity is not reached through an agent of mine"
    assert other.reload.concourse_agent
  end
end
