require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/concourse_test_helper"

class Bots::ConcourseAgentsControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include ConcourseTestHelper

  setup do
    sign_in_via_ajent
    @bot = User.find_by!(oidc_sub: "42").bots.sole # tenancy-ok: test reads the person it signed in
  end

  test "the person enters the bot's machine client, and saving tests the connection" do
    get bot_path(@bot)
    assert_select "#concourse", /Off/
    assert_select "#concourse input[placeholder='avery/durable-assistants']"

    stub_concourse_session
    patch bot_concourse_agent_path(@bot), params: { concourse_agent: { organization: "avery", handle: "avery/durable-assistants", client_id: "client-1", client_secret: "secret-1" } }

    assert_redirected_to bot_path(@bot)
    assert_equal "Connected to Concourse as avery/durable-assistants in avery.", flash[:notice]
    agent = @bot.reload.concourse_agent
    assert agent.connected?
    assert_equal "secret-1", agent.client_secret
    assert_not_includes ConcourseAgent.connection.select_value("SELECT client_secret FROM concourse_agents WHERE id = #{agent.id}"), "secret-1"

    follow_redirect!
    assert_select "#concourse", /Connected as avery\/durable-assistants in avery/
    assert_select "#concourse input[name='concourse_agent[client_secret]'][value]", count: 0
  end

  test "a blank secret keeps the saved one; a failed check is shown" do
    create_concourse_agent(@bot)
    stub_concourse_token
    stub_concourse_identity(handle: "other")

    patch bot_concourse_agent_path(@bot), params: { concourse_agent: { organization: "avery", handle: "avery/durable-assistants", client_id: "client-1", client_secret: "" } }

    assert_equal "secret-1", @bot.reload.concourse_agent.client_secret
    assert_match(/connection failed: These credentials belong to avery\/other in avery/, flash[:alert])
    assert_not @bot.concourse_agent.connected?
  end

  test "a malformed handle is refused before any call" do
    patch bot_concourse_agent_path(@bot), params: { concourse_agent: { organization: "avery", handle: "https://x", client_id: "c", client_secret: "s" } }

    assert_match(/must look like avery\/avery/, flash[:alert])
    assert_nil @bot.reload.concourse_agent
  end

  test "disconnecting removes the identity" do
    create_concourse_agent(@bot)

    delete bot_concourse_agent_path(@bot)

    assert_redirected_to bot_path(@bot)
    assert_nil @bot.reload.concourse_agent
  end

  test "someone else's bot is not found" do
    other = create_user(name: "Other").bots.sole

    patch bot_concourse_agent_path(other), params: { concourse_agent: { organization: "avery", handle: "avery/durable-assistants", client_id: "c", client_secret: "s" } }

    assert_response :not_found
    assert_nil other.reload.concourse_agent
  end
end
