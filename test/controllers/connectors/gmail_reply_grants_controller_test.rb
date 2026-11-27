require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

class Connectors::GmailReplyGrantsControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  setup do
    @owner = create_user(name: "Alice", email: "owner@example.com")
    @member = create_user(name: "Lee", email: "member@example.com")
    @workspace = Workspace.make(name: "Front desk", owner: @owner)
    @workspace.memberships.create!(user: @member, role: "member")
    @agent = @workspace.agents.create!(user: @owner, name: "Front desk", instructions: "Help.", model: Agent.models.first)
    @connector = @workspace.mcp_servers.create!(name: "gmail", user: @member, **McpServer.gallery_attributes("gmail"), tools: [],
      refreshed_at: Time.current, asks_every_write: true, oauth_tokens: { "access_token" => "sample-token", "signed_in_at" => Time.current.to_i })
  end

  test "the workspace owner adds and revokes one reply address on the selected connector" do
    sign_in_as(@owner)
    get connector_path(@connector)
    assert_select "#gmail_reply_grants", /No reply grants/
    assert_select "#gmail_reply_grant_agent_id option[value='#{@agent.id}']", @agent.name
    assert_select "input[type=email][placeholder='name@example.net']"
    add_grant(address: " PAT@example.net ")
    assert_redirected_to connector_path(@connector)
    follow_redirect!
    grant = @connector.gmail_reply_grants.sole
    assert_equal [ @agent, "pat@example.net" ], [ grant.agent, grant.address ]
    assert_select "#gmail_reply_grants", /pat@example.net/
    assert_select "#gmail_reply_grants button", "Revoke"
    assert_select "#connector_asks_every_write[role=switch][checked]"
    add_grant(address: "new@example.net")
    assert_equal [ "pat@example.net" ], @connector.gmail_reply_grants.pluck(:address)

    delete connector_gmail_reply_grant_path(@connector, grant)
    assert_redirected_to connector_path(@connector)
    follow_redirect!
    assert_select "#gmail_reply_grants", /No reply grants/
    assert_empty @connector.gmail_reply_grants
  end

  test "a member, even the person who added the connector, cannot grant or revoke" do
    grant = @connector.gmail_reply_grants.create!(agent: @agent, address: "pat@example.net")
    sign_in_as(@member)
    get connector_path(@connector)
    assert_select "#gmail_reply_grants", count: 0
    add_grant
    assert_response :not_found
    delete connector_gmail_reply_grant_path(@connector, grant)
    assert_response :not_found
    assert_equal grant, @connector.gmail_reply_grants.sole
  end

  test "an agent or grant from a different workspace cannot be reached" do
    foreign = @owner.personal_workspace.mcp_servers.create!(name: "another", user: @owner, **McpServer.gallery_attributes("gmail"), tools: [],
      refreshed_at: Time.current, oauth_tokens: { "access_token" => "sample-token" })
    other_agent = @owner.personal_workspace.agents.sole
    foreign_grant = foreign.gmail_reply_grants.create!(agent: other_agent, address: "pat@example.net")
    sign_in_as(@owner)
    add_grant(agent: other_agent)
    assert_response :not_found
    delete connector_gmail_reply_grant_path(@connector, foreign_grant)
    assert_response :not_found
    assert_equal foreign_grant, foreign.gmail_reply_grants.sole
    assert_empty @connector.gmail_reply_grants
  end

  test "only a bare mailbox is accepted and signing out removes existing grants" do
    sign_in_as(@owner)
    add_grant(address: "Pat <pat@example.net>")
    assert_empty @connector.gmail_reply_grants
    add_grant
    assert_equal 1, @connector.gmail_reply_grants.count
    @connector.sign_out
    add_grant
    follow_redirect!
    assert_select "#gmail_reply_grants", /Sign in to Gmail before allowing replies/
    assert_empty @connector.gmail_reply_grants
  end

  private
    def sign_in_as(user)
      sign_in_via_ajent(subject: user.oidc_sub, email: user.email, name: user.name)
    end

    def add_grant(agent: @agent, address: "pat@example.net")
      post connector_gmail_reply_grants_path(@connector), params: { gmail_reply_grant: { agent_id: agent.id, address: address } }
    end
end
