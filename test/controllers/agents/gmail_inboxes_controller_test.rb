require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

class Agents::GmailInboxesControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  GMAIL = "https://gmail.googleapis.com/gmail/v1/users/me/profile"
  OWNER = "owner@example.com"
  MAILBOX = "desk@example.net"
  MEMBER = "member@example.com"

  setup do
    @owner = create_user(name: "Workspace owner", email: OWNER)
    @member = create_user(name: "Workspace member", email: MEMBER)
    @workspace = Workspace.make(name: "Shared workspace", owner: @owner)
    @workspace.memberships.create!(user: @member, role: "member")
    @agent = @workspace.agents.create!(user: @owner, name: "Desk", instructions: "Help.", model: Agent.models.first)
    @connector = gmail_connector(@workspace, @member)
  end

  test "the workspace owner can bind the connector's signed-in mailbox even when it isn't their own email" do
    sign_in_as(@owner)
    get agent_channels_path(@agent)
    assert_select "a[href='#{agent_channels_path(@agent)}']", /Channels/, "the switch is reachable without any other channels"
    assert_select "#gmail_inbox [role=switch]:not([checked])"
    assert_select "#gmail_inbox .ui-group__help", /every member of this workspace can read/

    verified = profile("DESK@example.net")
    update_inbox(mailbox: " Desk@example.net ")
    assert_redirected_to agent_channels_path(@agent)
    inbox = @agent.reload.gmail_inbox
    assert inbox.enabled?
    assert_equal [ @owner.id, @connector.id, MAILBOX, "101" ], inbox.values_at(:enabled_by_id, :mcp_server_id, :mailbox, :history_id)
    assert_requested verified, times: 1
    follow_redirect!
    assert_select "#gmail_inbox [role=switch][checked]"
    assert_includes response.body, "Mail from #{MAILBOX} will appear in #{@agent.name}"
    assert_not_includes response.body, "This install has no channels set up"

    patch agent_gmail_inbox_path(@agent), params: { gmail_inbox: { enabled: "0" } }
    assert_redirected_to agent_channels_path(@agent)
    assert_not inbox.reload.enabled?
    assert_requested verified, times: 1
  end

  test "the owner can find and use Channels when Gmail is the only option on the install" do
    sign_in_as(@owner)
    with_setting(:concourse, :origin, nil) do
      get agent_path(@agent)
      assert_select "a[href='#{agent_channels_path(@agent)}']", /Channels/
      get agent_channels_path(@agent)
      assert_select "#gmail_inbox [role=switch]"
      assert_not_includes response.body, "This install has no channels set up"
    end
  end

  test "a member who created the connector never sees the active switch and cannot enable it even for their own Gmail" do
    sign_in_as(@member)
    get agent_channels_path(@agent)
    assert_response :success
    assert_select "#gmail_inbox", count: 0
    update_inbox(mailbox: MEMBER)
    assert_response :not_found
    assert_nil @agent.reload.gmail_inbox
    assert_not_requested :get, GMAIL
  end

  test "the owner cannot bind an address other than the connector's signed-in mailbox" do
    sign_in_as(@owner)
    verified = profile(OWNER)
    update_inbox
    assert_response :unprocessable_entity
    assert_select "#gmail_inbox [role=alert]", /must match the mailbox you entered/
    assert_nil @agent.reload.gmail_inbox
    assert_requested verified, times: 1
  end

  test "turning it on without naming the mailbox does not read Gmail" do
    sign_in_as(@owner)
    profile(OWNER)
    update_inbox(mailbox: " ")
    assert_response :unprocessable_entity
    assert_select "#gmail_inbox [role=alert]", /Enter the Gmail address/
    assert_nil @agent.reload.gmail_inbox
    assert_not_requested :get, GMAIL
  end

  test "the owner sees why a changed Gmail sign-in paused the inbox" do
    inbox = @agent.create_gmail_inbox!(mcp_server: @connector, enabled_by: @owner, mailbox: MAILBOX, history_id: "101", enabled: true)
    @connector.update!(oauth_tokens: { "access_token" => "replacement" })
    changed = profile(MEMBER, token: "replacement")
    GmailInboxFetchJob.perform_now(inbox)

    sign_in_as(@owner)
    get agent_channels_path(@agent)
    assert_response :success
    assert_select "#gmail_inbox [role=switch]:not([checked])"
    assert_select "#gmail_inbox [role=status]", /Paused: The connector is signed in to a different Gmail account/
    assert_not_includes response.body, MEMBER
    assert_requested changed, times: 1
  end

  test "turning it on without choosing a connector shows an error and leaves polling off" do
    sign_in_as(@owner)
    patch agent_gmail_inbox_path(@agent), params: { gmail_inbox: { enabled: "1", mcp_server_id: "" } }
    assert_response :unprocessable_entity
    assert_select "#gmail_inbox [role=alert]", /Choose a Gmail connector/
    assert_nil @agent.reload.gmail_inbox
    assert_not_requested :get, GMAIL
  end

  test "a connector named from another workspace is refused without looking at its Gmail" do
    sign_in_as(@owner)
    foreign = gmail_connector(@member.personal_workspace, @member)
    update_inbox(connector: foreign)
    assert_response :not_found
    assert_nil @agent.reload.gmail_inbox
    assert_not_requested :get, GMAIL
  end

  test "an admitted person sharing the install owner identity still cannot turn on the owner's Gmail" do
    with_setting(:access, :owner_email, OWNER) do
      sign_in_as(@member)
      get agent_channels_path(@agent)
      assert_response :success
      assert_select "#gmail_inbox", count: 0
      update_inbox
      assert_response :not_found
    end
    assert_not_requested :get, GMAIL
  end

  private
    def sign_in_as(user)
      sign_in_via_ajent(subject: user.oidc_sub, email: user.email, name: user.name)
    end

    def update_inbox(connector: @connector, mailbox: MAILBOX)
      patch agent_gmail_inbox_path(@agent), params: { gmail_inbox: { enabled: "1", mcp_server_id: connector.id, mailbox: mailbox } }
    end

    def gmail_connector(workspace, user)
      workspace.mcp_servers.create!(name: "gmail", user: user, url: "https://gmailmcp.googleapis.com/mcp/v1",
        oauth_scope: "https://www.googleapis.com/auth/gmail.readonly", oauth_tokens: { "access_token" => "synthetic-access" })
    end

    def profile(email, token: "synthetic-access")
      stub_request(:get, GMAIL).with(headers: { "Authorization" => "Bearer #{token}" })
        .to_return(body: { emailAddress: email, historyId: "101" }.to_json)
    end
end
