require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# One agents list across workspaces (#174): every workspace the person is in,
# their own first, each with its agents, how many cards wait there and a link
# into each thread, in place of choosing one workspace at a time. Bob is in his
# own workspace and Acorn, which Alice owns; Cedar is Carol's alone.
class AgentsListByWorkspaceTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  APP = { "User-Agent" => "Hotwire Native iOS; Turbo Native iOS; bridge-components: [button]" }.freeze

  setup do
    install_sidecar_settings
    @alice = create_user(name: "Alice")
    @carol = create_user(name: "Carol")
    @acorn = Workspace.create!(name: "Acorn")
    @acorn.memberships.create!(user: @alice, role: "owner")
    @cedar = Workspace.create!(name: "Cedar")
    @cedar.memberships.create!(user: @carol, role: "owner")
    @ada = @alice.start_agent("Ada", workspace: @acorn)
    @cy = @carol.start_agent("Cypress", workspace: @cedar)
    @bob = create_user(name: "Bob")
    @acorn.memberships.create!(user: @bob, role: "member")
    @own = @bob.personal_workspace.agents.sole
    sign_in_via_ajent(subject: "sub-bob", email: "bob@example.com", name: "Bob")
  end
  teardown { remove_sidecar_settings }

  test "a person in two workspaces sees both, his own first, each with its agents and waiting cards, and no other workspace" do
    waiting(@ada, "Which day suits?")
    waiting(@ada, "Which hotel?")
    waiting(@cy, "Carol's question")

    get root_path
    assert_response :success

    assert_equal [ "Bob Yours", "Acorn 2 people 2 waiting" ], css_select(".agent-group__title").map { it.text.squish }
    assert_select "#group_workspace_#{@bob.personal_workspace.id}" do
      assert_select ".agent-group__title a[href=?]", workspace_path(@bob.personal_workspace), text: "Bob"
      assert_select ".conversation-row a[href=?]", conversation_path(@own.conversation), text: /#{@own.name}/
      assert_select ".conversation-row", count: 1
    end
    assert_select "#group_workspace_#{@acorn.id}" do
      assert_select ".agent-group__title a[href=?]", workspace_path(@acorn), text: "Acorn"
      assert_select ".conversation-row a[href=?]", conversation_path(@ada.conversation), text: /Ada/
      assert_select ".conversation-row", count: 1
    end
    assert_select "#group_workspace_#{@cedar.id}", count: 0
    assert_select "#group_workspace_#{@alice.personal_workspace.id}", count: 0
    assert_no_match "Cedar", response.body
    assert_no_match "Cypress", response.body
    assert_no_match "Carol's question", response.body

    # Each group is live on its own workspace's stream, and on no other's.
    [ @bob.personal_workspace, @acorn ].each do |workspace|
      assert_includes response.body, Turbo::StreamsChannel.signed_stream_name([ workspace, :conversations ])
    end
    assert_not_includes response.body, Turbo::StreamsChannel.signed_stream_name([ @cedar, :conversations ])
  end

  test "a link into another workspace's thread opens it there" do
    stub_page_load(@ada.conversation)
    get conversation_path(@ada.conversation)
    assert_response :success
    assert_equal @acorn.id, session[:workspace_id]
  end

  test "the switcher is gone from the list and from beside a thread; the groups take its place in both" do
    get root_path
    assert_select ".workspace-switcher", count: 0
    assert_select ".page a.workspace-name", count: 0
    assert_select ".agent-group", count: 2

    stub_page_load(@own.conversation)
    get conversation_path(@own.conversation)
    assert_select ".workspace-switcher", count: 0
    assert_select ".chat-sidebar .agent-group", count: 2
    assert_select ".chat-sidebar #group_workspace_#{@acorn.id} .conversation-row a[href=?]", conversation_path(@ada.conversation)
    assert_select ".chat-sidebar #row_conversation_#{@own.conversation.id} [aria-current=page]"
  end

  test "Overview and New workspace, which the switcher led to, stay one tap from the list" do
    get root_path
    assert_select ".agent-groups__more a[href=?]", workspaces_overview_path, text: "Overview"
    assert_select ".agent-groups__more a[href=?]", new_workspace_path, text: "New workspace"
  end

  test "an empty workspace says so in its group, with a new agent made there" do
    @ada.destroy!
    get root_path
    assert_select "#group_workspace_#{@acorn.id} .agent-group__empty", text: /No agents yet/
    assert_select "#group_workspace_#{@acorn.id} .agent-group__empty a[href=?]", new_agent_path(workspace_id: @acorn.id)

    get new_agent_path(workspace_id: @acorn.id)
    assert_select "select[name='agent[workspace_id]'] option[selected][value=?]", @acorn.id.to_s
    assert_select "select[name='agent[workspace_id]'] option[value=?]", @cedar.id.to_s, count: 0

    post agents_path, params: { agent: { name: "Planner", workspace_id: @acorn.id } }
    assert_equal @acorn, @bob.agents.find_by!(name: "Planner").workspace

    post agents_path, params: { agent: { name: "Intruder", workspace_id: @cedar.id } }
    assert_response :not_found
    assert_not Agent.exists?(name: "Intruder") # tenancy-ok: proving nothing was made anywhere
  end

  test "search and filter run across every workspace, and a group with nothing to show is left out" do
    get conversations_path(q: "Ada")
    assert_select ".agent-group", count: 1
    assert_select "#group_workspace_#{@acorn.id} .conversation-row", text: /Ada/

    get conversations_path(q: "zebra")
    assert_select ".agent-group", count: 0
    assert_select ".ui-marker", text: /Nothing matches "zebra"\./
  end

  test "thirty a group, and a lazy frame for the rest of that group alone" do
    30.times { |index| @alice.start_agent("Talk #{index}", workspace: @acorn) }

    get root_path
    assert_select "#group_workspace_#{@acorn.id} .conversation-row", count: 30
    frame = "page_2_workspace_#{@acorn.id}"
    assert_select "turbo-frame##{frame}[loading=lazy][src=?]", conversations_path(page: 2, workspace_id: @acorn.id)

    get conversations_path(page: 2, workspace_id: @acorn.id)
    assert_select "turbo-frame##{frame} .conversation-row", count: 1
    assert_select ".agent-group", count: 1

    get conversations_path(page: 2, workspace_id: @cedar.id)
    assert_response :not_found
  end

  test "in the phone app the list is grouped too, with nothing to switch" do
    get root_path, headers: APP
    assert_response :success
    assert_select ".agent-group", count: 2
    assert_select ".workspace-switcher", count: 0
    assert_select "#group_workspace_#{@acorn.id} .conversation-row a[href=?]", conversation_path(@ada.conversation)
  end

  private
    def waiting(agent, question)
      agent.conversation.invocations.create!(task_id: "7", call_id: "toolu_#{question.hash.abs}", tool_name: "ask_person",
        arguments: { "question" => question }, digest: question, state: "awaiting_person", expires_at: 1.day.from_now)
    end

    def stub_page_load(conversation)
      conversation.update!(durable_id: "d-#{conversation.id}") unless conversation.durable_id
      stub_request(:get, "#{SIDECAR}/v1/conversations/#{conversation.durable_id}/entries").with(query: hash_including({}))
        .to_return(body: { entries: [], cursor: nil, more: false }.to_json)
      stub_request(:get, "#{SIDECAR}/v1/conversations/#{conversation.durable_id}").with(query: hash_including({}))
        .to_return(body: { status: "idle" }.to_json)
    end
end
