require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/mcp_test_helper"

# A personal workspace's owner, who doesn't own the install, gives it its own
# key for an office connector on the same page a shared workspace's owner
# uses, then turns it on (#168). Nobody else reaches that page, and the key is
# never shown again.
class PersonalInstallConnectorTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include McpTestHelper
  include ActiveJob::TestHelper

  WIKI = "http://example-wiki:3000/mcp".freeze
  OWN_WIKI = "https://wiki.olive.example.com/mcp".freeze
  OWN_KEY = "olive-wiki-key-made-up".freeze

  setup do
    @previous = Rails.application.config.x.install_connectors
    Rails.application.config.x.install_connectors = { wiki: { url: WIKI, api_key: "install-wiki-key", tools: %w[ search ] } }
    stub_mcp_server(url: WIKI, tools: [ mcp_tool("search") ])
    stub_mcp_server(url: OWN_WIKI, tools: [ mcp_tool("search") ])
    # The test install serves nobody (ACCESS__OWNER_EMAIL), so the install's key isn't Olive's.
    @owner = create_user(name: "Olive")
    @bob = create_user(name: "Bob")
    @carol = create_user(name: "Carol")
    @personal = @owner.personal_workspace
    # Shared workspaces let each of them in: Olive and Bob share one, Carol has her own.
    Workspace.make(name: "Household", owner: @owner).memberships.create!(user: @bob, role: "member")
    Workspace.make(name: "Elsewhere", owner: @carol)
    sign_in_via_ajent(subject: "sub-olive", email: "olive@example.com", name: "Olive")
  end
  teardown { Rails.application.config.x.install_connectors = @previous }

  test "the owner sets the personal workspace's own key, never sees it again, and turns the connector on" do
    get connectors_path
    assert_select "#office_connector_wiki a[href='#{edit_workspace_install_connector_path(@personal, "wiki")}']"
    get workspace_path(@personal)
    assert_select "#install_connector_wiki", text: /None/

    get edit_workspace_install_connector_path(@personal, "wiki")
    assert_response :success
    patch workspace_install_connector_path(@personal, "wiki"), params: { install_connector: { url: OWN_WIKI, api_key: OWN_KEY } }
    assert_redirected_to workspace_path(@personal)
    assert_equal [ OWN_WIKI, OWN_KEY ], @personal.install_connectors.sole.then { [ it.url, it.api_key ] }

    follow_redirect!
    assert_select "#install_connector_wiki", text: /Its own key and address/
    assert_no_match OWN_KEY, response.body
    get edit_workspace_install_connector_path(@personal, "wiki")
    assert_no_match OWN_KEY, response.body
    get connectors_path
    assert_select "#office_connector_wiki button", text: "Turn on"
    assert_no_match OWN_KEY, response.body

    perform_enqueued_jobs { post office_connectors_path, params: { name: "wiki" } }
    wiki = @personal.mcp_servers.find_by!(install: "wiki")
    assert_redirected_to connector_path(wiki)
    assert wiki.enabled?
    assert_equal [ OWN_WIKI, { "Authorization" => "Bearer #{OWN_KEY}" } ], [ wiki.url, wiki.request_headers ]
  end

  test "another member of it, or another person, finds no such page" do
    @personal.install_connectors.create!(name: "wiki", api_key: OWN_KEY)
    @personal.memberships.create!(user: @bob, role: "member")

    [ [ "sub-bob", "bob@example.com", "Bob" ], [ "sub-carol", "carol@example.com", "Carol" ] ].each do |subject, email, name|
      sign_in_via_ajent(subject: subject, email: email, name: name)
      get edit_workspace_install_connector_path(@personal, "wiki")
      assert_response :not_found, name
      patch workspace_install_connector_path(@personal, "wiki"), params: { install_connector: { api_key: "theirs" } }
      assert_response :not_found, name
      delete workspace_install_connector_path(@personal, "wiki")
      assert_response :not_found, name
    end
    assert_equal OWN_KEY, @personal.install_connectors.sole.api_key
  end
end
