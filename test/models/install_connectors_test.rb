require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/mcp_test_helper"

# The office's connectors (config/install_connectors.yml): every person has
# each whose key is set, inside the host over plain http, its key read from
# settings.
class InstallConnectorsTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include McpTestHelper
  include ActiveJob::TestHelper

  WIKI = "http://example-wiki:3000/mcp".freeze

  setup do
    @previous = Rails.application.config.x.install_connectors
    Rails.application.config.x.install_connectors = { wiki: { url: WIKI, api_key: "wiki-key", tools: %w[ search read_* ] } }
  end

  teardown { Rails.application.config.x.install_connectors = @previous }

  test "everyone has it, its tools limited to its patterns, its key read from settings and never kept" do
    listed = stub_mcp_server(url: WIKI, tools: %w[ search read_page delete_everything ].map { mcp_tool(it) })
    alice = create_user(name: "Alice")
    perform_enqueued_jobs(only: McpServerRefreshJob)

    wiki = alice.mcp_servers.sole
    assert_equal [ "wiki", "wiki", WIKI ], [ wiki.name, wiki.install, wiki.url ]
    assert_equal %w[ search read_page ], wiki.reload.tools.pluck("name")
    assert_requested listed.with(headers: { "Authorization" => "Bearer wiki-key" }), at_least_times: 1
    assert_nil wiki.headers
    assert_equal %w[ mcp__wiki__search mcp__wiki__read_page ], alice.agents.sole.conversation.tools.map(&:tool_name).grep(/wiki/)
  end

  test "the file may keep its tools out of every request, for find_tools to find" do
    stub_mcp_server(url: WIKI, tools: %w[ search read_page ].map { mcp_tool(it) })
    Rails.application.config.x.install_connectors[:wiki][:loaded] = false
    alice = create_user(name: "Alice")
    perform_enqueued_jobs(only: McpServerRefreshJob)

    assert_not alice.mcp_servers.sole.loaded?
    assert_empty alice.agents.sole.conversation.tools.map(&:tool_name).grep(/wiki/)
    assert_match "wiki (search, read_page)", alice.agents.sole.conversation.tool("find_tools").description

    Rails.application.config.x.install_connectors[:wiki][:loaded] = true
    InstallConnectorsJob.perform_now
    assert alice.mcp_servers.sole.loaded?
  end

  test "a person cannot add plain http to the install's host, nor remove the install's; they switch it off" do
    alice = create_user(name: "Alice")
    assert_not alice.mcp_servers.new(name: "mine", url: WIKI).valid?

    sign_in_via_ajent
    operator = User.find_by!(oidc_sub: "42") # tenancy-ok: test reads the person it signed in
    wiki = operator.mcp_servers.find_by!(install: "wiki")
    delete connector_path(wiki)
    assert McpServer.exists?(wiki.id) # tenancy-ok: proves it survived
    patch connector_path(wiki), params: { connector: { enabled: false } }
    assert_not wiki.reload.enabled?
  end

  test "without its key, it goes from everyone; a person's own connector of the same name is left alone" do
    alice = create_user(name: "Alice")
    bob = User.create!(oidc_sub: "sub-bob", email: "bob@example.com", name: "Bob")
    bob.mcp_servers.create!(name: "wiki", url: MCP_URL)
    InstallConnectorsJob.perform_now
    assert_equal [ nil ], bob.mcp_servers.pluck(:install)

    Rails.application.config.x.install_connectors[:wiki][:api_key] = nil
    InstallConnectorsJob.perform_now
    assert_empty alice.mcp_servers.reload
    assert_equal [ MCP_URL ], bob.mcp_servers.pluck(:url)
  end
end
