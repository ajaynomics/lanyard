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

    assert_equal [ "Yours", "Acorn 2 people 2 waiting" ], css_select(".agent-group__title").map { it.text.squish }
    assert_select "#group_workspace_#{@bob.personal_workspace.id}" do
      assert_select ".agent-group__title a[href=?]", workspace_path(@bob.personal_workspace), text: "Yours"
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

  test "a whole workspace renders without paging and a tree refresh stays scoped to membership" do
    30.times { |index| @alice.start_agent("Talk #{index}", workspace: @acorn) }

    get root_path
    assert_select "#group_workspace_#{@acorn.id} .conversation-row", count: 31
    assert_select "turbo-frame[loading=lazy]", count: 0

    get conversations_path(workspace_id: @acorn.id)
    assert_select ".conversation-row", count: 31
    get conversations_path(workspace_id: @cedar.id)
    assert_response :not_found
  end

  test "in the phone app the list is grouped too, with nothing to switch" do
    get root_path, headers: APP
    assert_response :success
    assert_select ".agent-group", count: 2
    assert_select ".workspace-switcher", count: 0
    assert_select "#group_workspace_#{@acorn.id} .conversation-row a[href=?]", conversation_path(@ada.conversation)
  end

  test "the native shell renders List for saved, direct and frame Chart requests without forgetting the desktop lens" do
    lead = @alice.start_agent("Birch lead", workspace: @acorn).tap { it.update!(parent_id: @ada.id) }
    leaf = @alice.start_agent("Alder report", workspace: @acorn).tap { it.update!(parent_id: lead.id) }
    get conversations_path(lens: "chart")
    assert_select ".tree--chart"

    [ conversations_path, conversations_path(lens: "chart") ].each do |path|
      get path, headers: APP
      assert_select ".agent-lenses, .tree--chart", count: 0
      assert_select ".tree > li[data-agent=?] ul > li[data-agent=?] ul > li[data-agent=?] a[href=?]",
        @ada.id, lead.id, leaf.id, conversation_path(leaf.conversation)
    end
    frame = "agents_workspace_#{@acorn.id}"
    get conversations_path(lens: "chart", sort: "title", filter: "all", workspace_id: @acorn.id), headers: APP.merge("Turbo-Frame" => frame)
    assert_select "turbo-frame##{frame} .tree:not(.tree--chart) > li[data-agent=?] ul > li[data-agent=?] ul > li[data-agent=?]",
      @ada.id, lead.id, leaf.id
    get conversations_path
    assert_select ".agent-lenses [aria-current=page]", text: "Chart"
  end

  test "a search or filter opens a closed branch so a matching report shows, and keeps it closed after" do
    lead = @alice.start_agent("Birch lead", workspace: @acorn)
    report = @alice.start_agent("Birch report", workspace: @acorn).tap { it.update!(parent_id: lead.id) }
    [ lead, report ].each { it.conversation.update!(status: "waiting") }
    cookies[:collapsed_agents] = lead.id.to_s

    [ conversations_path(q: "Birch"), conversations_path(filter: "waiting") ].each do |path|
      get path
      assert_select ".tree > li[data-agent=?] > details[data-group=?][open] li[data-agent=?] a[href=?]",
        lead.id, lead.id, report.id, conversation_path(report.conversation)
      assert_nil response.cookies["collapsed_agents"]
    end

    get conversations_path
    assert_select "details[data-group=?]:not([open])", lead.id
    assert_select "details[data-group=?][data-was-open=false]", lead.id
  end

  test "chart remembers its lens and scopes a three-tier tree and card counts to visible workspaces" do
    report = @alice.start_agent("A very long name for the agent reporting to Ada", workspace: @acorn)
    indirect = @alice.start_agent("Coordinator", workspace: @acorn)
    report.update!(parent_id: @ada.id, title: "Project coordinator")
    indirect.update!(parent_id: report.id)
    waiting(report, "Visible question")
    report.conversation.update!(status: "waiting")
    waiting(@cy, "Hidden question")

    get conversations_path(lens: "chart")
    assert_select ".tree--chart > li[data-agent=?] ul > li[data-agent=?] ul > li[data-agent=?]", @ada.id, report.id, indirect.id
    assert_select "#row_conversation_#{report.conversation.id}[data-standing='needs_you'][data-waiting='1']"
    assert_select "#group_workspace_#{@cedar.id}", count: 0
    assert_not_includes response.body, "Hidden question"

    get conversations_path
    assert_select "[aria-current='page']", text: "Chart"
    assert_select ".tree--chart", count: 2

    get conversations_path(workspace_id: @acorn.id, lens: "chart"), headers: { "Turbo-Frame" => "agents_workspace_#{@acorn.id}" }
    assert_select "turbo-frame#agents_workspace_#{@acorn.id} .tree--chart"
    get conversations_path(workspace_id: @cedar.id, lens: "chart"), headers: { "Turbo-Frame" => "agents_workspace_#{@cedar.id}" }
    assert_response :not_found

    get conversations_path(lens: "list")
    assert_select ".tree--chart", count: 0
    get conversations_path
    assert_select "[aria-current='page']", text: "List"
  end

  test "an empty workspace stays usable in chart view" do
    @ada.destroy!
    get conversations_path(lens: "chart")
    assert_select "#group_workspace_#{@acorn.id} .agent-group__empty a[href=?]", new_agent_path(workspace_id: @acorn.id)
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
