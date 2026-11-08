require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# "New agent from here": a whole new agent whose thread starts as a copy of
# another's up to a reply, in place of the branches there were.
class NewAgentFromHereTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: test reads the person it signed in
    @conversation = create_conversation(@agent)
    @agent = @conversation.agent
    name_agent(@agent, "Trip planner")
    @agent.update!(instructions: "You are Trip planner. Plan Maya's trips.")
    @agent.skills.create!(name: "packing", description: "Make a packing list.", body: "List what to pack.")
    @agent.notes.create!(key: "passport", body: "Expires in May.")
    @conversation.messages.create!(entry_key: "4", entry_id: 4, role: "user", content: "Where should I go?")
    @answer = @conversation.messages.create!(entry_key: "5", entry_id: 5, role: "assistant", content: "Lisbon.")
  end
  teardown { remove_sidecar_settings }

  test "the reply and the agent's menu lead to the form, which says what it copies" do
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/12}).to_return(status: 503, body: { error: "unavailable" }.to_json)
    get conversation_path(@conversation)
    assert_select "#messages a[href=?]", new_agent_path(from: @answer.id), text: "New agent from here"
    assert_select "#chat_actions a[href=?]", new_agent_path(from: @answer.id), text: "New agent from here"

    get new_agent_path(from: @answer.id)
    assert_response :ok
    assert_select "h1", "New agent"
    assert_select "input[type=hidden][name=from][value=?]", @answer.id.to_s
    assert Agent::Access.valid_id?(css_select("input[type=hidden][name=request_id]").sole["value"])
    assert_select "#agent_from", text: /Starts with a copy of Trip planner's thread up to its reply from .*, and its instructions, skills and notes\./m
  end

  test "makes a new agent with the instructions, skills and notes, its thread forked from the reply into its own workspace" do
    asked = nil
    fork = stub_request(:post, "#{SIDECAR}/v1/conversations/12/forks").with { asked = JSON.parse(it.body) }
      .to_return(status: 201, body: { id: 40 }.to_json)

    assert_difference -> { @agent.user.agents.count } do
      post agents_path, params: { from: @answer.id, request_id: "n-1", agent: { name: "Lisbon guide", purpose: "Knows Lisbon." } }
    end

    guide = @agent.user.agents.find_by!(name: "Lisbon guide")
    assert_redirected_to conversation_path(guide.conversation)
    assert_requested fork
    assert_equal({ "requestId" => "n-1", "at" => 5, "actorId" => @agent.user_id.to_s, "workspaceId" => @agent.id.to_s,
                   "into" => { "workspaceId" => guide.id.to_s, "cwd" => guide.workdir } }, asked)
    assert_equal "40", guide.conversation.durable_id
    assert_equal "You are Lisbon guide. Plan Maya's trips.\n\n## Your purpose\n\nKnows Lisbon.", guide.instructions, "told its own name, not the other's"
    assert_equal [ [ "packing", "Make a packing list.", "List what to pack." ] ], guide.skills.pluck(:name, :description, :body)
    assert_equal [ [ "passport", "Expires in May." ] ], guide.notes.pluck(:key, :body)
    assert_not_equal @agent.email_name, guide.email_name
    # The source is unchanged.
    assert_equal [ "You are Trip planner. Plan Maya's trips.", 1, 1 ], [ @agent.reload.instructions, @agent.skills.count, @agent.notes.count ]
  end

  test "a sidecar that cannot fork leaves no agent, and the form says so" do
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/forks").to_return(status: 503, body: { error: "unavailable" }.to_json)

    assert_no_difference -> { Agent.count } do # tenancy-ok: nothing anywhere is left half made
      assert_no_difference [ -> { Skill.count }, -> { Note.count }, -> { Conversation.count } ] do # tenancy-ok: as above
        post agents_path, params: { from: @answer.id, request_id: "n-2", agent: { name: "Lisbon guide" } }
      end
    end

    assert_response :unprocessable_entity
    assert_select ".flash", /thread could not be copied just now, so no agent was made/
    assert_select "input[name='agent[name]'][value=?]", "Lisbon guide"
    retry_id = css_select("input[type=hidden][name=request_id]").sole["value"]
    assert Agent::Access.valid_id?(retry_id)
    assert_not_equal "n-2", retry_id, "a retry is a new request: the sidecar tied n-2 to the agent that was not kept"
  end

  test "only the person's own finished reply, with a request id" do
    robin = create_user(name: "Robin")
    theirs = create_conversation(robin.agents.sole, durable_id: "99")
    their_answer = theirs.messages.create!(entry_key: "5", entry_id: 5, role: "assistant", content: "Porto.")
    calling = @conversation.messages.create!(entry_key: "6", entry_id: 6, role: "assistant", content: "",
      tool_calls: [ { "id" => "c", "name" => "current_time" } ])

    get new_agent_path(from: their_answer.id)
    assert_response :not_found
    post agents_path, params: { from: their_answer.id, request_id: "n-3", agent: { name: "Mine now" } }
    assert_response :not_found

    get new_agent_path(from: calling.id)
    assert_response :bad_request
    post agents_path, params: { from: @answer.id, request_id: "not a request id!", agent: { name: "Lisbon guide" } }
    assert_response :bad_request
    assert_not @agent.user.agents.exists?(name: "Lisbon guide")
  end
end
