require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/concourse_test_helper"

# Join Concourse, against the stand-in for Concourse's join (FakeConcourse):
# Concourse's page, the callback, and where the agent stands after.
class Agents::ConcourseJoinsControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include ConcourseTestHelper

  setup do
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: test reads the person it signed in
    @concourse = stub_fake_concourse
  end

  test "Join sends the browser to Concourse's page with every parameter the contract names" do
    get agent_channels_path(@agent)
    assert_select "#concourse", /Not joined/
    assert_select "#concourse form[action='#{agent_concourse_join_path(@agent)}'][data-turbo='false'] button", "Join Concourse"
    assert_select "input[name='concourse_agent[client_secret]']", count: 0

    post agent_concourse_join_path(@agent)

    assert_response :redirect
    location = URI(response.location)
    assert_equal "#{ORIGIN}/connect", "#{location.scheme}://#{location.host}#{location.path}"
    query = URI.decode_www_form(location.query).to_h
    assert_equal({ "response_type" => "code", "redirect_uri" => "http://localhost/concourse/callback", "code_challenge_method" => "S256",
                   "handle" => "assistant", "name" => "Assistant", "app_name" => DurableAssistants.config(:app, :name) },
      query.except("state", "code_challenge"))
    assert_operator Base64.urlsafe_decode64(query["state"]).bytesize * 8, :>=, 128
    assert_match(/\A[A-Za-z0-9_-]{43}\z/, query["code_challenge"])
  end

  test "approved, the agent keeps its encrypted client and waits; a minute later it is asked again and is connected" do
    join_and_approve

    assert_redirected_to agent_channels_path(@agent)
    assert_equal "Assistant asked to join acme as acme/assistant. An owner there must approve it.", flash[:notice]
    concourse_agent = @agent.reload.concourse_agent
    assert concourse_agent.awaiting_approval?
    assert_equal [ "acme", "acme/assistant", "joined-2", "joined-secret-2" ], concourse_agent.values_at(:organization, :handle, :client_id, :client_secret)
    assert_not_includes ConcourseAgent.connection.select_value("SELECT client_secret FROM concourse_agents WHERE id = #{concourse_agent.id}"), "joined-secret-2"
    assert_not_includes @agent.tools([]), Tool::ConcourseSend

    follow_redirect!
    assert_select "#concourse", /Waiting for approval/
    assert_select "#concourse", /Waiting for an owner of acme to approve acme\/assistant\./
    assert_select "#concourse button", "Disconnect"

    @concourse.admit!
    get agent_channels_path(@agent)
    assert_select "#concourse", /Waiting for approval/, "asked again within the minute"

    travel 1.minute + 1.second do
      get agent_channels_path(@agent)
    end
    assert_select "#concourse", /Connected/
    assert_select "#concourse .channel__address", "acme/assistant"
    assert @agent.reload.concourse_agent.connected?
    assert_includes @agent.tools([]), Tool::ConcourseSend
  end

  test "an agent Concourse admits at once is connected when the browser comes back" do
    @concourse.admit_on_join = true

    join_and_approve

    assert_equal "Assistant joined Concourse as acme/assistant.", flash[:notice]
    assert @agent.reload.concourse_agent.connected?
  end

  test "a cancelled join changes nothing" do
    @concourse.cancel = true

    join_and_approve

    assert_redirected_to agent_channels_path(@agent)
    assert_equal "You cancelled joining Concourse.", flash[:notice]
    assert_nil @agent.reload.concourse_agent
  end

  test "a callback with another state, a used one or a late one changes nothing" do
    post agent_concourse_join_path(@agent)
    callback = approve_on_concourse

    get concourse_callback_path(code: "code-1", state: "forged")
    assert_match(/doesn't match a join you started/, flash[:alert])
    assert_nil @agent.reload.concourse_agent

    travel 10.minutes + 1.second do
      get callback
    end
    assert_match(/doesn't match a join you started/, flash[:alert])
    assert_nil @agent.reload.concourse_agent
    assert_empty @concourse.agents
  end

  test "a code Concourse refuses changes nothing" do
    post agent_concourse_join_path(@agent)
    callback = approve_on_concourse
    state = URI.decode_www_form(URI(callback).query).to_h["state"]

    get concourse_callback_path(code: "code-99", state: state)

    assert_equal "Concourse refused the join (invalid_grant). Start again.", flash[:alert]
    assert_nil @agent.reload.concourse_agent
  end

  test "a declined agent shows why, and joining again forgets it first" do
    join_and_approve
    @concourse.decline!
    travel 1.minute + 1.second do
      get agent_channels_path(@agent)
    end
    assert_select "#concourse", /Declined/
    assert_select "#concourse", /acme declined acme\/assistant\./
    assert_select "#concourse button", "Join again"

    post agent_concourse_join_path(@agent)

    assert_nil @agent.reload.concourse_agent
    assert_match %r{\A#{ORIGIN}/connect\?}, response.location
  end

  test "an agent on Concourse already, or waiting, is not joined again" do
    join_and_approve

    post agent_concourse_join_path(@agent)

    assert_match(/on Concourse already/, flash[:alert])
    assert @agent.reload.concourse_agent.awaiting_approval?
  end

  test "someone else's agent is not found" do
    other = create_user(name: "Robin").agents.sole

    post agent_concourse_join_path(other)

    assert_response :not_found
    assert_nil session[:concourse_join]
  end

  test "asked to join, an agent with join_concourse gives the page's link; one button there joins; once joined, both say so" do
    conversation = create_conversation(@agent)
    assert_not_includes conversation.definition[:tools].pluck(:name), "join_concourse"
    @agent.update!(tool_names: @agent.tool_names + [ "join_concourse" ])
    assert_includes conversation.reload.definition[:tools].pluck(:name), "join_concourse"

    assert_equal({ link: "http://localhost#{new_agent_concourse_join_path(@agent)}",
                   say: "Give the person this link. On that page they join you to Concourse with one button." }, join_concourse(conversation, "c1"))

    get new_agent_concourse_join_path(@agent)
    assert_select "h1", "Join Concourse as Assistant"
    assert_select "form[action='#{agent_concourse_join_path(@agent)}'][data-turbo='false'] button", "Join Concourse"

    join_and_approve
    assert_equal({ joined: "acme/assistant", status: "waiting for an owner of acme to approve" }, join_concourse(conversation, "c2"))
    get new_agent_concourse_join_path(@agent)
    assert_select "p", /on Concourse already, as acme\/assistant/
    assert_select "form[action='#{agent_concourse_join_path(@agent)}']", count: 0
  end

  test "another person's agent has no join page" do
    theirs = create_user(name: "Robin").agents.sole
    get new_agent_concourse_join_path(theirs)
    assert_response :not_found
  end

  private
    def join_concourse(conversation, call_id)
      payload = invocation_payload(conversation, tool: "join_concourse", arguments: {}, call_id: call_id)
      Invocation.receive(conversation, task_id: payload[:taskId], call_id: call_id, tool: "join_concourse",
        arguments: {}, digest: payload[:digest]).deep_symbolize_keys[:result]
    end

    # Join, the person approves on Concourse's page, and the browser comes back.
    def join_and_approve
      post agent_concourse_join_path(@agent)
      get approve_on_concourse
    end

    def approve_on_concourse
      answer = Net::HTTP.get_response(URI(response.location))
      URI(answer["location"]).then { "#{it.path}?#{it.query}" }
    end
end
