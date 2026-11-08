require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/concourse_test_helper"

class Agents::ConcourseAgentsControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include ConcourseTestHelper

  setup do
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: test reads the person it signed in
  end

  test "the person enters the agent's machine client, and saving tests the connection" do
    get agent_channels_path(@agent)
    assert_select "#concourse", /Off/
    assert_select "#concourse input[placeholder='acme/assistant']"

    stub_concourse_session
    patch agent_concourse_agent_path(@agent), params: { concourse_agent: { organization: "acme", handle: "acme/assistant", client_id: "client-1", client_secret: "secret-1" } }

    assert_redirected_to agent_channels_path(@agent)
    assert_equal "Connected to Concourse as acme/assistant in acme.", flash[:notice]
    concourse_agent = @agent.reload.concourse_agent
    assert concourse_agent.connected?
    assert_equal "secret-1", concourse_agent.client_secret
    assert_not_includes ConcourseAgent.connection.select_value("SELECT client_secret FROM concourse_agents WHERE id = #{concourse_agent.id}"), "secret-1"

    follow_redirect!
    assert_select "#concourse", /Connected as acme\/assistant in acme/
    assert_select "#concourse input[name='concourse_agent[client_secret]'][value]", count: 0
  end

  test "a blank secret keeps the saved one; a failed check is shown" do
    create_concourse_agent(@agent)
    stub_concourse_token
    stub_concourse_identity(handle: "other")

    patch agent_concourse_agent_path(@agent), params: { concourse_agent: { organization: "acme", handle: "acme/assistant", client_id: "client-1", client_secret: "" } }

    assert_equal "secret-1", @agent.reload.concourse_agent.client_secret
    assert_match(/connection failed: These credentials belong to acme\/other in acme/, flash[:alert])
    assert_not @agent.concourse_agent.connected?
  end

  test "a malformed handle is refused before any call" do
    patch agent_concourse_agent_path(@agent), params: { concourse_agent: { organization: "acme", handle: "https://x", client_id: "c", client_secret: "s" } }

    assert_match(/must look like acme\/assistant/, flash[:alert])
    assert_nil @agent.reload.concourse_agent
  end

  test "disconnecting removes the identity" do
    create_concourse_agent(@agent)

    delete agent_concourse_agent_path(@agent)

    assert_redirected_to agent_channels_path(@agent)
    assert_nil @agent.reload.concourse_agent
  end

  test "someone else's agent is not found" do
    other = create_user(name: "Other").agents.sole

    patch agent_concourse_agent_path(other), params: { concourse_agent: { organization: "acme", handle: "acme/assistant", client_id: "c", client_secret: "s" } }

    assert_response :not_found
    assert_nil other.reload.concourse_agent
  end
end
