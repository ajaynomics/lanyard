require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

class Connectors::ConversationGmailReplyGrantsControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  setup do
    @owner = create_user(name: "Alice", email: "owner@example.com")
    @member = create_user(name: "Lee", email: "member@example.com")
    @workspace = Workspace.make(name: "Front desk", owner: @owner)
    @workspace.memberships.create!(user: @member, role: :member)
    @agent = @owner.start_agent("Front desk", workspace: @workspace)
    @connector = @workspace.mcp_servers.create!(name: "gmail", user: @member, conversation: @agent.conversation,
      **McpServer.gallery_attributes("gmail"), refreshed_at: Time.current,
      oauth_tokens: { "access_token" => "sample-token", "signed_in_at" => Time.current.to_i })
    @page = conversation_connectors_path(@agent.conversation)
  end

  test "the owner sees and manages a grant for the fixed agent even while the signed-in connector is off" do
    @connector.update!(enabled: false)
    sign_in_as(@owner)
    get agent_tools_path(@agent)
    assert_select "a[href='#{@page}']", /own connectors/
    get @page
    assert_response :success
    assert_select "form[action='#{connector_gmail_reply_grants_path(@connector)}']" do
      assert_select "input[type=email][name='gmail_reply_grant[address]']"
      assert_select "[name='gmail_reply_grant[agent_id]']", count: 0
    end

    assert_difference -> { @connector.gmail_reply_grants.count }, 1 do
      add_grant(address: " PAT@example.net ", agent_id: @owner.personal_workspace.agents.sole.id)
      assert_redirected_to @page
    end
    grant = @connector.gmail_reply_grants.sole
    assert_equal [ @agent, "pat@example.net" ], [ grant.agent, grant.address ]
    assert_not @connector.reload.enabled?
    follow_redirect!
    assert_select "form[action='#{connector_gmail_reply_grant_path(@connector, grant)}'] button", "Revoke"

    delete connector_gmail_reply_grant_path(@connector, grant)
    assert_redirected_to @page
    follow_redirect!
    assert_select "form[action='#{connector_gmail_reply_grants_path(@connector)}']"
    assert_empty @connector.gmail_reply_grants
  end

  test "the workspace owner can post directly to the existing grant route without an agent parameter" do
    sign_in_as(@owner)
    add_grant
    assert_redirected_to @page
    assert_equal @agent, @connector.gmail_reply_grants.sole.agent
  end

  test "only the workspace owner can add or revoke even if a member owns the connector sign-in" do
    grant = @connector.gmail_reply_grants.create!(agent: @agent, address: "pat@example.net")
    sign_in_as(@member)
    get @page
    assert_response :success
    assert_select "form[action='#{connector_gmail_reply_grants_path(@connector)}']", count: 0
    assert_select "form[action='#{connector_gmail_reply_grant_path(@connector, grant)}']", count: 0
    assert_no_difference -> { @connector.gmail_reply_grants.count } do
      add_grant
      assert_response :not_found
      delete connector_gmail_reply_grant_path(@connector, grant)
      assert_response :not_found
    end
  end

  test "another workspace owner cannot reach the connector or its grant" do
    grant = @connector.gmail_reply_grants.create!(agent: @agent, address: "pat@example.net")
    sign_in_as(create_user(name: "Jo", email: "operator@example.com"))
    get @page
    assert_response :not_found
    add_grant
    assert_response :not_found
    delete connector_gmail_reply_grant_path(@connector, grant)
    assert_response :not_found
    assert_equal grant, @connector.gmail_reply_grants.sole
  end

  test "one bare address per connector and no grant for an unrelated agent" do
    sign_in_as(@owner)
    other = @owner.start_agent("Other desk", workspace: @workspace)
    assert_not @connector.gmail_reply_grants.new(agent: other, address: "pat@example.net").valid?
    add_grant(address: "Pat <pat@example.net>")
    assert_not @connector.gmail_reply_grants.exists?
    add_grant
    add_grant(address: "lee@example.net", agent_id: other.id)
    assert_equal [ "pat@example.net" ], @connector.gmail_reply_grants.pluck(:address)
  end

  test "signing out clears the grant and leaves only the sign-in guidance" do
    sign_in_as(@owner)
    add_grant
    delete connector_sign_in_path(@connector)
    assert_redirected_to @page
    assert_empty @connector.gmail_reply_grants
    add_grant
    assert_redirected_to @page
    follow_redirect!
    assert_select "p", "Sign in to Gmail before allowing replies."
    assert_select "form[action='#{connector_gmail_reply_grants_path(@connector)}']", count: 0
    assert_empty @connector.gmail_reply_grants
  end

  private
    def add_grant(**values)
      post connector_gmail_reply_grants_path(@connector), params: { gmail_reply_grant: { address: "pat@example.net", **values } }
    end

    def sign_in_as(user)
      sign_in_via_ajent(subject: user.oidc_sub, email: user.email, name: user.name)
    end
end
