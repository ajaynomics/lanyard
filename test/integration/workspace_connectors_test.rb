require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# Connectors belong to a workspace (docs/design/workspaces.md, section 2.4): a
# shared workspace's agents use its connectors, and its members manage them on
# its connector pages. A person's personal connectors never reach a shared
# workspace, nor the shared one's theirs. Alice owns the shared workspace and
# added its connector; Bob is a member; each has a personal connector.
class WorkspaceConnectorsTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include ActiveJob::TestHelper

  setup do
    install_sidecar_settings
    @alice = create_user(name: "Alice", email: "member@example.com")
    sign_in_via_ajent(name: "Bob")
    @bob = User.find_by!(oidc_sub: "42") # tenancy-ok: test reads the person it signed in
    @bob.start_agent("Bob's own") if @bob.agents.none?
    @shared = Workspace.create!(name: "Household")
    @shared.memberships.create!(user: @alice, role: "owner")
    @bobs_membership = @shared.memberships.create!(user: @bob, role: "member")
    @shared_agent = @alice.start_agent("Cook", workspace: @shared)

    @shared_connector = @shared.mcp_servers.create!(user: @alice, name: "recipes", url: "https://recipes.example.com/mcp")
    @alices_own = @alice.personal_workspace.mcp_servers.create!(user: @alice, name: "mail", url: "https://mail.example.com/mcp")
    @bobs_own = @bob.personal_workspace.mcp_servers.create!(user: @bob, name: "bank", url: "https://bank.example.com/mcp")
  end
  teardown { remove_sidecar_settings }

  test "a shared workspace's agents use its connectors, never a member's personal ones; a personal agent never the shared ones" do
    assert_equal [ @shared_connector ], @shared_agent.conversation.connectors
    assert_equal [ @alices_own ], @alice.personal_workspace.agents.sole.conversation.connectors
    assert_equal [ @bobs_own ], @bob.personal_workspace.agents.sole.conversation.connectors
  end

  test "in the shared workspace Bob manages its connector, made by Alice, and never reaches Alice's personal ones" do
    get workspace_connectors_path(@shared)
    assert_response :success
    assert_select "h2", text: "Household's connectors"
    assert_select "a[href='#{connector_path(@shared_connector)}']"
    assert_select "a[href='#{connector_path(@bobs_own)}']", count: 0
    get connector_path(@shared_connector)
    assert_response :success
    patch connector_path(@shared_connector), params: { connector: { enabled: "0" } }
    assert_not @shared_connector.reload.enabled?

    get connector_path(@alices_own)
    assert_response :not_found
    patch connector_path(@alices_own), params: { connector: { enabled: "0" } }
    assert_response :not_found
    assert @alices_own.reload.enabled?

    # His own opens in his own workspace, as a thread of his would.
    get connector_path(@bobs_own)
    assert_response :success
    assert_equal @bob.personal_workspace.id, session[:workspace_id]
  end

  test "a connector Bob adds in the shared workspace is the workspace's, used by its agents and Alice alike" do
    get workspace_path(@shared)
    post connectors_path, params: { connector: { name: "notes", url: "https://notes.example.com/mcp", token: "t" } }

    added = @shared.mcp_servers.find_by!(name: "notes")
    assert_equal @bob, added.user
    assert_includes @shared_agent.conversation.connectors, added
    assert_not_includes @bob.personal_workspace.agents.sole.conversation.connectors, added
  end

  test "his personal workspace's connectors list his own, never the shared one's, nor does a stranger reach his" do
    get workspace_connectors_path(@bob.personal_workspace)
    assert_select "h2", text: "Your connectors"
    assert_select "a[href='#{connector_path(@bobs_own)}']"
    assert_select "a[href='#{connector_path(@shared_connector)}']", count: 0

    @bobs_membership.destroy!
    get connector_path(@shared_connector)
    assert_response :not_found
    delete connector_path(@shared_connector)
    assert_response :not_found
    assert McpServer.exists?(@shared_connector.id) # tenancy-ok: test checks the row survived
  end

  test "a removed member can no longer reach the shared workspace's connector" do
    get workspace_path(@shared)
    get connector_path(@shared_connector)
    assert_response :success

    @bobs_membership.destroy!
    get connector_path(@shared_connector)
    assert_response :not_found
    patch connector_path(@shared_connector), params: { connector: { enabled: "0" } }
    assert_response :not_found
    post connector_sign_in_path(@shared_connector)
    assert_response :not_found
    assert @shared_connector.reload.enabled?
  end

  test "one name in two workspaces is two connectors, and a conversation's own must be in its agent's workspace" do
    @shared.mcp_servers.create!(user: @alice, name: "mail", url: "https://mail.example.com/mcp")
    stray = @alice.personal_workspace.mcp_servers.new(user: @alice, conversation: @shared_agent.conversation, name: "stray", url: "https://x.example.com/mcp")
    assert_not stray.valid?
  end
end
