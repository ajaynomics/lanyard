require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/mcp_test_helper"

# The office's connectors (config/install_connectors.yml): a workspace turned
# one on has it, inside the host over plain http, its key read from settings
# (the install's only in the office owner's workspaces, #168).
class InstallConnectorsTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include McpTestHelper
  include ActiveJob::TestHelper

  WIKI = "http://example-wiki:3000/mcp".freeze

  setup do
    @previous = Rails.application.config.x.install_connectors
    Rails.application.config.x.install_connectors = { wiki: { url: WIKI, api_key: "wiki-key", tools: %w[ search read_* ] } }
    @owner_email, Rails.application.config.x.office[:owner_email] = Rails.application.config.x.office[:owner_email], "operator@example.com"
  end

  teardown do
    Rails.application.config.x.install_connectors = @previous
    Rails.application.config.x.office[:owner_email] = @owner_email
  end

  test "turned on, its tools are limited to its patterns, its key read from settings and never kept" do
    listed = stub_mcp_server(url: WIKI, tools: %w[ search read_page delete_everything ].map { mcp_tool(it) })
    alice = install_owner
    perform_enqueued_jobs(only: McpServerRefreshJob)

    wiki = alice.mcp_servers.sole
    assert_equal [ "wiki", "wiki", WIKI ], [ wiki.name, wiki.install, wiki.url ]
    assert_equal %w[ search read_page ], wiki.reload.tools.pluck("name")
    assert_requested listed.with(headers: { "Authorization" => "Bearer wiki-key" }), at_least_times: 1
    assert_nil wiki.headers
    conversation = alice.agents.sole.conversation
    assert_empty conversation.tools.map(&:tool_name).grep(/wiki/), "without `loaded`, looked up, as any new connector is"
    assert_equal %w[ mcp__wiki__search mcp__wiki__read_page ], conversation.lookup_tools.map(&:tool_name).grep(/wiki/)
  end

  test "each workspace has its own, a shared one's used by its agents and reaching no member's personal one" do
    stub_mcp_server(url: WIKI, tools: %w[ search ].map { mcp_tool(it) })
    alice, bob = install_owner, create_user(name: "Bob")
    shared = Workspace.create!(name: "Household")
    shared.memberships.create!(user: alice, role: "owner")
    shared.memberships.create!(user: bob, role: "member")
    agent = alice.start_agent("Cook", workspace: shared)
    McpServer.turn_on(shared, "wiki")

    2.times { InstallConnectorsJob.perform_now }

    wiki = shared.mcp_servers.sole
    assert_equal [ "wiki", alice ], [ wiki.install, wiki.user ]
    assert_equal [ wiki ], agent.conversation.connectors
    own = alice.personal_workspace.mcp_servers.sole
    assert_equal [ "wiki", [ own ] ], [ own.install, alice.personal_workspace.agents.sole.conversation.connectors ]
    assert_empty bob.personal_workspace.mcp_servers
  end

  # An install adds an entry of its own beside core's, in a second file it
  # keeps, instead of replacing core's file (docs/office.md).
  test "an install's own file adds an entry under every rule of core's, and an entry without its key goes to nobody" do
    Dir.mktmpdir do |dir|
      local = Pathname(dir).join("install_connectors.local.yml")
      local.write(<<~YAML)
        shared:
          ledger:
            url: http://example-ledger:8080/mcp
            api_key: <%= "ledger-key" %>
            loaded: false
            tools: [ "read_*" ]
          drafts:
            url: http://example-drafts:8080/mcp
      YAML
      Rails.application.config.x.install_connectors = DurableAssistants.install_connectors(
        { wiki: { url: WIKI, api_key: "wiki-key", tools: %w[ search ] } }, local)
    end
    listed = stub_mcp_server(url: "http://example-ledger:8080/mcp", tools: %w[ read_book write_book ].map { mcp_tool(it) })
    stub_mcp_server(url: WIKI, tools: [ mcp_tool("search") ])
    alice = install_owner.tap { McpServer.turn_on(it.personal_workspace, "ledger") }
    assert_not McpServer.turn_on(alice.personal_workspace, "drafts").persisted?
    perform_enqueued_jobs(only: McpServerRefreshJob)

    assert_equal %w[ ledger wiki ], alice.mcp_servers.order(:install).pluck(:install), "no key, no drafts"
    ledger = alice.mcp_servers.find_by!(install: "ledger")
    assert ledger.valid?, "plain http to its own host inside the network, as core's entries"
    assert_equal %w[ read_book ], ledger.tools.pluck("name")
    assert_requested listed.with(headers: { "Authorization" => "Bearer ledger-key" }), at_least_times: 1
    assert_equal %w[ mcp__ledger__read_book ], alice.agents.sole.conversation.lookup_tools.map(&:tool_name) & %w[ mcp__ledger__read_book ]
  end

  test "an install's own file can't replace core's entry of the same name: the boot fails" do
    Dir.mktmpdir do |dir|
      local = Pathname(dir).join("install_connectors.local.yml")
      local.write("shared:\n  wiki:\n    url: http://elsewhere:3000/mcp\n    api_key: other\n")
      error = assert_raises(ArgumentError) { DurableAssistants.install_connectors({ wiki: { url: WIKI } }, local) }
      assert_match "install_connectors.local.yml can't redefine wiki", error.message
    end
  end

  test "without an install's own file, core's entries are all there is" do
    own = { wiki: { url: WIKI } }
    assert_equal own, DurableAssistants.install_connectors(own, Pathname("/nonexistent/install_connectors.local.yml"))
  end

  test "a workspace whose owner was deleted gets none, and the sweep goes on" do
    gone = create_user(name: "Gone")
    left = gone.personal_workspace
    gone.destroy!
    alice = install_owner

    InstallConnectorsJob.perform_now

    assert_empty left.mcp_servers
    assert_equal [ "wiki" ], alice.personal_workspace.mcp_servers.map(&:install)
  end

  test "the file says core or lookup for each of the person's agents: core where it fits, and where it doesn't, a move said once" do
    stub_mcp_server(url: WIKI, tools: %w[ search read_page ].map { mcp_tool(it) })
    Rails.application.config.x.install_connectors[:wiki][:loaded] = false
    alice = install_owner
    perform_enqueued_jobs(only: McpServerRefreshJob)
    agent, wiki = alice.agents.sole, alice.mcp_servers.sole

    assert_not agent.core?(wiki)
    assert_empty agent.conversation.tools.map(&:tool_name).grep(/wiki/)
    assert_match "Connectors: wiki.", agent.conversation.tool("find_tools").description

    # Another agent of hers, at the limit: its own connector fills the room another looked-up one leaves.
    alice.mcp_servers.create!(name: "notes", url: MCP_URL, tools: [ { "name" => "jot", "input_schema" => { "type" => "object" } } ])
    crowded = alice.start_agent("Crowded")
    room = Agent::TOOL_LIMIT - crowded.tool_count
    crowded.workspace.mcp_servers.new(user: alice, name: "big", url: MCP_URL, conversation: crowded.conversation, refreshed_at: Time.current,
      tools: Array.new(room) { { "name" => "tool_#{it}", "input_schema" => { "type" => "object" } } }).save!(validate: false)
    assert_equal Agent::TOOL_LIMIT, crowded.reload.tool_count

    Rails.application.config.x.install_connectors[:wiki][:loaded] = true
    2.times { InstallConnectorsJob.perform_now }
    assert agent.reload.core?(wiki)
    assert_equal %w[ mcp__wiki__search mcp__wiki__read_page ], agent.conversation.reload.tools.map(&:tool_name).grep(/wiki/)
    assert_not crowded.reload.core?(wiki), "where it doesn't fit, it stays looked up, for that agent only"
    assert_equal [ "wiki" ], crowded.connector_moves.map(&:connector_name), "said once, not every ten minutes"
    assert_empty agent.connector_moves
    assert_match "wiki's tools are looked up now", crowded.conversation.reload.definition[:instructions]

    Rails.application.config.x.install_connectors[:wiki][:loaded] = false
    InstallConnectorsJob.perform_now
    assert_not agent.reload.core?(wiki)
  end

  # Before per-agent core, an install connector that did not fit one agent
  # stayed looked up for every agent. Applying `loaded: true` again on each
  # run would make it core where it now fits, and grow those agents at deploy.
  test "an existing connector the install says is core is not made core again on each run" do
    stub_mcp_server(url: WIKI, tools: %w[ search read_page ].map { mcp_tool(it) })
    Rails.application.config.x.install_connectors[:wiki][:loaded] = true
    alice = install_owner
    perform_enqueued_jobs(only: McpServerRefreshJob)
    agent, wiki = alice.agents.sole, alice.mcp_servers.sole
    assert agent.core?(wiki), "made core when it was made"

    # As the migration leaves one an older release had looked up: no core row, no word applied.
    agent.core_connectors.where(mcp_server: wiki).delete_all
    wiki.update_column(:install_core, nil) if wiki.has_attribute?(:install_core)
    before = agent.reload.tool_count
    2.times { InstallConnectorsJob.perform_now }
    assert_not agent.reload.core?(wiki)
    assert_equal before, agent.tool_count
    assert alice.start_agent("Later").core?(wiki), "an agent made later still gets it"
  end

  test "a person cannot add plain http to the install's host, nor remove the install's; they switch it off" do
    alice = create_user(name: "Alice")
    assert_not alice.mcp_servers.new(name: "mine", url: WIKI).valid?

    sign_in_via_ajent
    operator = User.find_by!(oidc_sub: "42") # tenancy-ok: test reads the person it signed in
    wiki = McpServer.turn_on(operator.personal_workspace, "wiki")
    delete connector_path(wiki)
    assert McpServer.exists?(wiki.id) # tenancy-ok: proves it survived
    patch connector_path(wiki), params: { connector: { enabled: false } }
    assert_not wiki.reload.enabled?
  end

  test "without its key, it goes from everyone; a person's own connector of the same name is left alone" do
    alice = install_owner
    bob = User.create!(oidc_sub: "sub-bob", email: "bob@example.com", name: "Bob")
    bob.mcp_servers.create!(name: "wiki", url: MCP_URL)
    InstallConnectorsJob.perform_now
    assert_equal [ nil ], bob.mcp_servers.pluck(:install)

    Rails.application.config.x.install_connectors[:wiki][:api_key] = nil
    InstallConnectorsJob.perform_now
    assert_empty alice.mcp_servers.reload
    assert_equal [ MCP_URL ], bob.mcp_servers.pluck(:url)
  end

  test "an agent acts as itself with its own key, the office's address and tool patterns holding with or without the shared key" do
    listed = stub_mcp_server(url: WIKI, tools: %w[ search read_page delete_everything ].map { mcp_tool(it) })
    alice = install_owner
    perform_enqueued_jobs(only: McpServerRefreshJob)
    conversation = alice.agents.sole.conversation
    Rails.application.config.x.install_connectors[:wiki][:api_key] = nil
    InstallConnectorsJob.perform_now
    assert_empty alice.mcp_servers.global.reload, "the shared one goes with the shared key"

    own = conversation.mcp_servers.create!(user: alice, name: "wiki", install: "wiki", url: WIKI, token: "jordan-key")
    McpServerRefreshJob.perform_now(own)
    assert_equal %w[ search read_page ], own.reload.tools.pluck("name")
    assert_requested listed.with(headers: { "Authorization" => "Bearer jordan-key" }), at_least_times: 1
    assert_equal %w[ mcp__wiki__search mcp__wiki__read_page ], conversation.reload.tools.map(&:tool_name).grep(/wiki/)
    assert_not conversation.mcp_servers.new(user: alice, name: "crm", url: "http://example-crm:3000/mcp", token: "k").valid?,
      "plain http inside the host is only for an address the office names"
  end

  private
    # The office's owner (OFFICE__OWNER_EMAIL), with the wiki turned on in their own workspace.
    def install_owner
      create_user(name: "Alice", email: "operator@example.com").tap { McpServer.turn_on(it.personal_workspace, "wiki") }
    end
end
