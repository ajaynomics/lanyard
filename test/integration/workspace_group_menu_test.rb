require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# Each workspace's group in the agents list has a menu (#174): New agent here,
# Connectors, Helpers, Invite people… and its page, each naming that workspace.
# Where a page leads comes from where the person is (a group's menu, a thread),
# never from a workspace chosen once and kept: "Work in it" is gone. Bob is in
# his own workspace, in Acorn, which Alice owns, and in Birch, which he owns;
# Cedar is Carol's alone.
class WorkspaceGroupMenuTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  setup do
    install_sidecar_settings
    @alice = create_user(name: "Alice")
    @carol = create_user(name: "Carol")
    @acorn = Workspace.create!(name: "Acorn")
    @acorn.memberships.create!(user: @alice, role: "owner")
    @cedar = Workspace.create!(name: "Cedar")
    @cedar.memberships.create!(user: @carol, role: "owner")
    @ada = @alice.start_agent("Ada", workspace: @acorn)
    @bob = create_user(name: "Bob")
    @acorn.memberships.create!(user: @bob, role: "member")
    @birch = Workspace.make(name: "Birch", owner: @bob)
    @own = @bob.personal_workspace.agents.sole
    @acorn_connector = @acorn.mcp_servers.create!(user: @alice, name: "recipes", url: "https://recipes.example.com/mcp")
    @own_connector = @bob.personal_workspace.mcp_servers.create!(user: @bob, name: "bank", url: "https://bank.example.com/mcp")
    @cedar_connector = @cedar.mcp_servers.create!(user: @carol, name: "ledger", url: "https://ledger.example.com/mcp")
    sign_in_via_ajent(subject: "sub-bob", email: "bob@example.com", name: "Bob")
  end
  teardown { remove_sidecar_settings }

  test "each group's menu leads into that group's workspace" do
    get root_path
    assert_response :success

    [ @bob.personal_workspace, @acorn, @birch ].each do |workspace|
      menu = "menu_workspace_#{workspace.id}"
      assert_select "#group_workspace_#{workspace.id} .agent-group__title button[popovertarget=?]", menu
      assert_select "##{menu}[popover]" do
        assert_select "a[href=?]", new_agent_path(workspace_id: workspace.id), text: "New agent here"
        assert_select "a[href=?]", workspace_connectors_path(workspace), text: "Connectors"
        assert_select "a[href=?]", workspace_helpers_path(workspace), text: "Helpers"
        assert_select "a[href=?]", workspace_path(workspace), text: "Workspace settings"
      end
    end
    assert_select "#menu_workspace_#{@cedar.id}", count: 0
  end

  # Whoever may invite into a workspace finds Invite people… in its menu, the
  # same rule as its invite form (Workspace#invites_from?): today its owner, when shared.
  test "the owner of a shared workspace finds Invite people… in its menu, leading to its invite form" do
    get root_path
    assert_select "#menu_workspace_#{@birch.id} a[href=?]", workspace_path(@birch, anchor: "invitations_title"), text: "Invite people…"
    assert_select "#menu_workspace_#{@bob.personal_workspace.id} a", text: "Invite people…", count: 0
    assert_select "a", text: "Share with…", count: 0

    get workspace_path(@birch)
    assert_select "#invitations_title"
    assert_select "form[action=?]", workspace_invitations_path(@birch)

    reset!
    sign_in_via_ajent(subject: "sub-alice", email: "alice@example.com", name: "Alice")
    assert_select "#menu_workspace_#{@acorn.id} a[href=?]", workspace_path(@acorn, anchor: "invitations_title"), text: "Invite people…"
  end

  test "a member who doesn't own the workspace finds no Invite people…, as its page shows no invite form" do
    get root_path
    assert_select "#menu_workspace_#{@acorn.id}" do
      assert_select "a", text: "Invite people…", count: 0
      assert_select "a", text: "Share with…", count: 0
    end

    get workspace_path(@acorn)
    assert_select "#invitations_title", count: 0
    assert_select "form[action=?]", workspace_invitations_path(@acorn), count: 0
  end

  test "an install that serves one person invites nobody, so no menu offers Invite people…" do
    with_setting(:access, :emails, [ "bob@example.com" ]) do
      with_setting(:access, :owner, "bob@example.com") do
        get root_path
        assert_select "#menu_workspace_#{@birch.id}"
        assert_select "a", text: "Invite people…", count: 0

        get workspace_path(@birch)
        assert_select "#invitations_refused"
        assert_select "form[action=?]", workspace_invitations_path(@birch), count: 0
      end
    end
  end

  test "Connectors and Helpers from group B's menu show B, though the last thread opened was in A" do
    stub_page_load(@own.conversation)
    get conversation_path(@own.conversation)
    assert_equal @bob.personal_workspace.id, session[:workspace_id]

    get workspace_connectors_path(@acorn)
    assert_response :success
    assert_select "h2", text: "Acorn's connectors"
    assert_select "a[href=?]", connector_path(@acorn_connector)
    assert_select "a[href=?]", connector_path(@own_connector), count: 0

    get workspace_helpers_path(@acorn)
    assert_response :success
    assert_select "#helpers_workspace", text: "In Acorn."

    # Another tab opens a thread in A; B's page, still open, keeps working in B.
    get conversation_path(@own.conversation)
    get connector_path(@acorn_connector)
    assert_response :success
    post connectors_path(workspace_id: @acorn.id), params: { connector: { name: "notes", url: "https://notes.example.com/mcp", token: "t" } }
    assert_equal @acorn, McpServer.find_by!(name: "notes").workspace # tenancy-ok: proving where the new one went

    get workspace_connectors_path(@cedar)
    assert_response :not_found
    get workspace_helpers_path(@cedar)
    assert_response :not_found
    get connector_path(@cedar_connector)
    assert_response :not_found
  end

  test "New agent from the top-level button starts in the workspace used last, and the form shows it to change" do
    stub_page_load(@ada.conversation)
    get conversation_path(@ada.conversation)
    get root_path
    assert_select "#new_agent[href=?]", new_agent_path

    get new_agent_path
    assert_select "select#agent_workspace_id option[selected][value=?]", @acorn.id.to_s, text: "Acorn"

    stub_page_load(@own.conversation)
    get conversation_path(@own.conversation)
    get new_agent_path
    assert_select "select#agent_workspace_id option[selected][value=?]", @bob.personal_workspace.id.to_s
  end

  test "inside a thread, New agent is in the thread's workspace" do
    stub_page_load(@ada.conversation)
    get conversation_path(@ada.conversation)
    assert_select ".chat__actions a.chat__new[href=?]", new_agent_path(workspace_id: @acorn.id)
    assert_select ".chat-sidebar__new[href=?]", new_agent_path(workspace_id: @acorn.id)
  end

  test "Work in it is gone: a workspace's page offers it nowhere, and nothing answers it" do
    get workspace_path(@acorn)
    assert_response :success
    assert_select "button", text: "Work in it", count: 0
    assert_select "#working_in_it", count: 0
    assert_select "form[action=?]", "/workspaces/#{@acorn.id}/selection", count: 0

    get workspaces_path
    assert_no_match "Working in it", response.body

    post "/workspaces/#{@acorn.id}/selection"
    assert_response :not_found
  end

  private
    def stub_page_load(conversation)
      conversation.update!(durable_id: "d-#{conversation.id}") unless conversation.durable_id
      stub_request(:get, "#{SIDECAR}/v1/conversations/#{conversation.durable_id}/entries").with(query: hash_including({}))
        .to_return(body: { entries: [], cursor: nil, more: false }.to_json)
      stub_request(:get, "#{SIDECAR}/v1/conversations/#{conversation.durable_id}").with(query: hash_including({}))
        .to_return(body: { status: "idle" }.to_json)
    end
end
