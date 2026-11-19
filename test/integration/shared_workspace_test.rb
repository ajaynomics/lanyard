require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# A request's lists are of one workspace, Current.workspace: the one the session
# names while the person belongs to it, and their personal one otherwise
# (docs/design/workspaces.md). A request about one agent, thread or card works
# in that record's workspace, if the person is in it. Alice and Bob each have a personal
# workspace, and share a third that Alice owns.
class SharedWorkspaceTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  setup do
    install_sidecar_settings
    @alice = create_user(name: "Alice", email: "member@example.com")
    sign_in_via_ajent(name: "Bob")
    @bob = User.find_by!(oidc_sub: "42") # tenancy-ok: test reads the person it signed in
    @bob.start_agent("Bob's own") if @bob.agents.none?

    @shared = Workspace.create!(name: "Household")
    @shared.memberships.create!(user: @alice, role: "owner")
    @bobs_membership = @shared.memberships.create!(user: @bob, role: "member")
    @shared_agent = @shared.agents.create!(user: @alice, name: "Shared", instructions: "Help.", model: Agent.models.first)
  end
  teardown { remove_sidecar_settings }

  test "Bob starts in his personal workspace, and never reaches Alice's" do
    get root_path
    assert_response :success
    assert_equal @bob.personal_workspace.id, session[:workspace_id]

    assert_reaches thread_of(@bob)
    assert_not_reached thread_of(@alice)
  end

  test "in the shared workspace Bob reaches its agents and threads, and never Alice's personal ones" do
    get workspace_path(@shared)
    assert_equal @shared.id, session[:workspace_id]

    assert_reaches @shared_agent.conversation
    get agent_path(@shared_agent)
    assert_response :success
    assert_not_reached thread_of(@alice)
    get agent_path(@alice.personal_workspace.agents.sole)
    assert_response :not_found
    assert_equal @shared.id, session[:workspace_id], "a link out of reach leaves him where he was"
  end

  test "in the shared workspace Alice reaches its threads, and never Bob's personal ones" do
    reset!
    sign_in_via_ajent(name: "Alice", subject: "sub-alice", email: "member@example.com")
    assert_reaches thread_of(@alice)
    assert_not_reached thread_of(@bob)

    get workspace_path(@shared)
    assert_reaches @shared_agent.conversation
    assert_not_reached thread_of(@bob)
  end

  # A notification or a shared link names a thread or an agent, not a
  # workspace: opening one in another of the person's workspaces works there.
  test "a link to a thread in another of Bob's workspaces opens it there, beside every workspace's agents" do
    assert_reaches @shared_agent.conversation
    assert_equal @shared.id, session[:workspace_id]
    assert_select "#group_workspace_#{@shared.id} ##{ActionView::RecordIdentifier.dom_id(@shared_agent.conversation, :row)}"
    assert_select "#group_workspace_#{@bob.personal_workspace.id} ##{ActionView::RecordIdentifier.dom_id(thread_of(@bob), :row)}"

    assert_reaches thread_of(@bob)
    assert_equal @bob.personal_workspace.id, session[:workspace_id]
  end

  test "a link to an agent's settings, or a card waiting on him, in another of Bob's workspaces opens it there" do
    get agent_instructions_path(@shared_agent)
    assert_response :success
    assert_equal @shared.id, session[:workspace_id]

    get workspace_path(@bob.personal_workspace)
    get agent_path(@shared_agent)
    assert_response :success
    assert_equal @shared.id, session[:workspace_id]

    get workspace_path(@bob.personal_workspace)
    invocation = @shared_agent.conversation.invocations.create!(task_id: "7", call_id: "toolu_q", tool_name: "ask_person",
      arguments: { "question" => "Tea?" }, digest: "q", state: "awaiting_person", expires_at: 1.hour.from_now)
    get approval_path(invocation)
    assert_response :success
    assert_equal @shared.id, session[:workspace_id]
  end

  test "only a page Bob opens switches: a change to what is in another of his workspaces is made there, and he stays" do
    patch agent_path(@shared_agent), params: { agent: { title: "Moved" } }
    assert_response :redirect
    assert_equal @bob.personal_workspace.id, session[:workspace_id]
    assert_equal "Moved", @shared_agent.reload.title

    get conversation_messages_path(@shared_agent.conversation, before: 1), headers: { "Turbo-Frame" => "earlier" }
    assert_equal @bob.personal_workspace.id, session[:workspace_id], "a frame filling in is not a page he opened"
  end

  test "a link into a workspace Bob is not in is not found, and he stays in his own" do
    get conversation_path(thread_of(@alice))
    assert_response :not_found
    get agent_path(@alice.personal_workspace.agents.sole)
    assert_response :not_found
    assert_equal @bob.personal_workspace.id, session[:workspace_id]
  end

  test "Bob cannot choose a workspace he is not in: 404, and he stays in his own" do
    get workspace_path(@alice.personal_workspace)
    assert_response :not_found

    assert_equal @bob.personal_workspace.id, session[:workspace_id]
    assert_not_reached thread_of(@alice)
  end

  test "removed from the shared workspace, Bob's next request finds nothing there and he is back in his own" do
    get workspace_path(@shared)
    assert_reaches @shared_agent.conversation

    @bobs_membership.destroy!

    get conversation_path(@shared_agent.conversation)
    assert_response :not_found
    assert_equal @bob.personal_workspace.id, session[:workspace_id]
    assert_reaches thread_of(@bob)
  end

  test "the agents list is every workspace he is in, whichever he works in" do
    get workspace_path(@shared)
    get conversations_path
    assert_select "##{ActionView::RecordIdentifier.dom_id(@shared_agent.conversation, :row)}"
    assert_select "##{ActionView::RecordIdentifier.dom_id(thread_of(@bob), :row)}"
    assert_select "##{ActionView::RecordIdentifier.dom_id(thread_of(@alice), :row)}", count: 0
  end

  test "each group leads to its workspace's page; the list to a new workspace; Settings' Workspaces to a new one too" do
    get root_path
    assert_select ".agent-group__title a[href=?]", workspace_path(@bob.personal_workspace), text: @bob.to_s
    assert_select ".agent-group__title a[href=?]", workspace_path(@shared), text: "Household"
    assert_select ".agent-groups__more a[href=?]", new_workspace_path

    get workspaces_path
    assert_select "a[href=?]", new_workspace_path, text: "New workspace"

    # Its members page is drawn as Settings' groups, from the agents list too.
    get workspace_path(@shared)
    assert_select "link[rel=stylesheet][href*=?]", "/settings-"
  end

  # The phone app draws its own bar and hides the page's title; the groups are the page's own, so they stay.
  test "in the phone app the agents list is grouped, each group with its menu" do
    app = { "User-Agent" => "Hotwire Native iOS; Turbo Native iOS; bridge-components: [button]" }
    get root_path, headers: app
    assert_equal [ "#{@bob} Yours", "Household 2 people" ], css_select(".agent-group__title").map { it.text.squish }

    assert_select "#menu_workspace_#{@shared.id}[popover] a[href=?]", workspace_connectors_path(@shared), text: "Connectors"
  end

  private
    def thread_of(user) = user.personal_workspace.agents.order(:id).first.conversation

    def assert_reaches(conversation)
      get conversation_path(conversation)
      assert_response :success, "reaches #{conversation.agent.name}'s thread"
    end

    def assert_not_reached(*conversations)
      conversations.each do |conversation|
        get conversation_path(conversation)
        assert_response :not_found, "#{conversation.agent.name}'s thread is out of reach"
      end
    end
end
