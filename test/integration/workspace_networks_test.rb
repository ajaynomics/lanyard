require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/passbolt_test_helper"

# A workspace's own place on the networks its agents talk on
# (docs/design/workspaces.md, 2.1 and 2.3): its Concourse home network, and
# its own Campfire, each set by its owner alone on the workspace's page.
class WorkspaceNetworksTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include PassboltTestHelper
  include ActiveJob::TestHelper

  CAMPFIRE = "https://chat.pilot.example.com".freeze
  # The bot test/lib/campfire_v1_5_8/bots-index.html lists, spelled in parts so no scanner takes it for a real key.
  BOT_KEY = [ 2, "SynthBotKey1" ].join("-").freeze

  setup do
    install_sidecar_settings
    sign_in_via_ajent(name: "Owner")
    @owner = User.find_by!(oidc_sub: "42") # tenancy-ok: test reads the person it signed in
    @member = create_user(name: "Bob", email: "member@example.com")
    @workspace = Workspace.create!(name: "Pilot")
    @workspace.memberships.create!(user: @owner, role: "owner")
    @workspace.memberships.create!(user: @member, role: "member")
    @agent = @workspace.agents.create!(user: @owner, name: "Iris", instructions: "Help.", model: Agent.models.first)
    get workspace_path(@workspace)
  end

  teardown do
    remove_fake_passbolt
    remove_sidecar_settings
  end

  test "the owner names the home network and the workspace's own Campfire on its page; a member sees neither and changes neither" do
    get workspace_path(@workspace)
    assert_select "#concourse_network input[name='workspace[concourse_home]']"
    assert_select "#campfire input[name='workspace[campfire_url]']"
    assert_select "#campfire input[name='workspace[campfire_vault_entry]']"
    assert_select "#campfire input[type=password]", { count: 0 }, "the administrator's password stays in the vault"

    patch workspace_concourse_network_path(@workspace), params: { workspace: { concourse_home: " pilot-net " } }
    assert_redirected_to workspace_path(@workspace)
    assert_equal "pilot-net", @workspace.reload.concourse_home
    patch workspace_concourse_network_path(@workspace), params: { workspace: { concourse_home: "not a network!" } }
    assert_response :unprocessable_entity
    assert_equal "pilot-net", @workspace.reload.concourse_home

    patch workspace_campfire_path(@workspace), params: { workspace: { campfire_url: "#{CAMPFIRE}/", campfire_vault_entry: "Pilot Campfire" } }
    assert_redirected_to workspace_path(@workspace)
    assert_equal [ CAMPFIRE, "Pilot Campfire" ], @workspace.reload.values_at(:campfire_url, :campfire_vault_entry)
    follow_redirect!
    assert_select "#campfire", /Its agents' bots are on #{Regexp.escape(CAMPFIRE)}/

    sign_in_via_ajent(subject: "sub-bob", email: "member@example.com", name: "Bob")
    get workspace_path(@workspace)
    get workspace_path(@workspace)
    assert_response :success
    assert_select "#concourse_network form", count: 0
    assert_select "#campfire form", count: 0
    patch workspace_concourse_network_path(@workspace), params: { workspace: { concourse_home: "elsewhere" } }
    assert_response :not_found
    patch workspace_campfire_path(@workspace), params: { workspace: { campfire_url: "https://evil.example.com" } }
    assert_response :not_found
    delete workspace_campfire_path(@workspace)
    assert_response :not_found
    assert_equal [ "pilot-net", CAMPFIRE ], @workspace.reload.values_at(:concourse_home, :campfire_url)

    sign_in_via_ajent(name: "Owner")
    get workspace_path(@workspace)
    delete workspace_campfire_path(@workspace)
    assert_nil @workspace.reload.campfire_url, "without one, the install's as before"
  end

  test "a workspace with its own Campfire makes, posts and reads as its agents' bots there, signing in with the vault's entry for that host alone" do
    install_fake_passbolt(name: "Pilot Campfire", uri: CAMPFIRE, password: "synthetic-campfire-password")
    @workspace.update!(campfire_url: CAMPFIRE, campfire_vault_entry: "Pilot Campfire")
    elsewhere = create_user(name: "Robin").agents.sole

    assert_equal CAMPFIRE, @agent.campfire.url
    assert @agent.campfire.admin?
    assert_not elsewhere.campfire.configured?, "another workspace has the install's, here none"
    assert @agent.reserved_sign_in?("pilot campfire"), "the administrator's sign-in is the app's, never the agent's to fill in"

    signed_in = stub_request(:post, "#{CAMPFIRE}/session").with(body: hash_including("email_address" => "maya", "password" => "synthetic-campfire-password"))
      .to_return(status: 302, headers: { "Location" => "#{CAMPFIRE}/", "Set-Cookie" => "session_token=abc; path=/" })
    stub_request(:get, "#{CAMPFIRE}/session/new").to_return(body: Rails.root.join("test/lib/campfire_v1_5_8/session-new.html").read, headers: { "Content-Type" => "text/html" })
    stub_request(:get, "#{CAMPFIRE}/account/bots").to_return(body: Rails.root.join("test/lib/campfire_v1_5_8/bots-index.html").read, headers: { "Content-Type" => "text/html" })
    assert @agent.campfire.admin.lists_key?(BOT_KEY)
    assert_requested signed_in, times: 1

    bot = @agent.create_campfire_bot!(bot_key: BOT_KEY)
    posted = stub_request(:post, "#{CAMPFIRE}/rooms/3/#{BOT_KEY}/messages").to_return(status: 201, headers: { "Location" => "#{CAMPFIRE}/messages/77" })
    assert_equal 77, bot.say(3, "Hello")
    assert_requested posted, times: 1
    assert_includes @agent.reload.tools([]).map(&:tool_name), "campfire_say"
    assert_equal "http://localhost/campfire/#{bot.token}", bot.webhook_url, "a Campfire of the workspace's own is told the app's address"

    remove_fake_passbolt
    install_fake_passbolt(name: "Pilot Campfire", uri: "https://bank.example/login", password: "synthetic-campfire-password")
    DurableAssistants::Campfire.forget_sessions
    error = assert_raises(DurableAssistants::Campfire::Error) { @agent.campfire.admin.lists_key?(BOT_KEY) }
    assert_equal "Pilot Campfire is saved for bank.example, not chat.pilot.example.com, so it is not sent there.", error.message
    assert_requested signed_in, times: 1
  end
end
