require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/mcp_test_helper"

# A workspace's own address and key for one of the install's connectors
# (Workspace::InstallConnector): its connector uses them instead of the
# install's, and no other workspace's does. Without one, a workspace has the
# install's exactly as before.
class WorkspaceInstallConnectorTest < ActiveSupport::TestCase
  include AgentTestHelper
  include McpTestHelper
  include ActiveJob::TestHelper

  WIKI = "http://example-wiki:3000/mcp".freeze
  ACORN_WIKI = "https://wiki.acorn.example.com/mcp".freeze

  setup do
    @previous = Rails.application.config.x.install_connectors
    Rails.application.config.x.install_connectors = { wiki: { url: WIKI, api_key: "install-wiki-key", tools: %w[ search ] } }
    @install_wiki = stub_mcp_server(url: WIKI, tools: [ mcp_tool("search"), mcp_tool("delete_everything") ])
    @acorn_wiki = stub_mcp_server(url: ACORN_WIKI, tools: [ mcp_tool("search"), mcp_tool("delete_everything") ])
    # The office's owner (OFFICE__OWNER_EMAIL): Acorn, theirs, may fall back on the install's key.
    @owner_email, Rails.application.config.x.office[:owner_email] = Rails.application.config.x.office[:owner_email], "operator@example.com"
    @alice = create_user(name: "Alice", email: "operator@example.com")
    @acorn = Workspace.create!(name: "Acorn")
    @acorn.memberships.create!(user: @alice, role: "owner")
    @agent = @alice.start_agent("Ada", workspace: @acorn)
  end
  teardown do
    Rails.application.config.x.install_connectors = @previous
    Rails.application.config.x.office[:owner_email] = @owner_email
  end

  test "its own address and key replace the install's for its agents alone, the office's tool patterns still holding" do
    perform_enqueued_jobs(only: McpServerRefreshJob) do
      @acorn.install_connectors.create!(name: "wiki", url: ACORN_WIKI, api_key: "acorn-wiki-key")
      McpServer.turn_on(@acorn, "wiki")
      McpServer.turn_on(@alice.personal_workspace, "wiki")
    end

    wiki = @acorn.mcp_servers.find_by!(install: "wiki")
    assert_equal ACORN_WIKI, wiki.url
    assert_equal({ "Authorization" => "Bearer acorn-wiki-key" }, wiki.request_headers)
    assert_equal %w[ search ], wiki.reload.tools.pluck("name")
    assert_requested @acorn_wiki.with(headers: { "Authorization" => "Bearer acorn-wiki-key" }), at_least_times: 1
    assert_not_requested :post, ACORN_WIKI, headers: { "Authorization" => "Bearer install-wiki-key" }

    own = @alice.personal_workspace.mcp_servers.find_by!(install: "wiki")
    assert_equal [ WIKI, { "Authorization" => "Bearer install-wiki-key" } ], [ own.url, own.request_headers ]
    assert_not_requested :post, WIKI, headers: { "Authorization" => "Bearer acorn-wiki-key" }
  end

  test "a key alone keeps the install's address; the key is kept encrypted" do
    @acorn.install_connectors.create!(name: "wiki", api_key: "acorn-wiki-key")
    McpServer.turn_on(@acorn, "wiki")
    wiki = @acorn.mcp_servers.find_by!(install: "wiki")
    assert_equal [ WIKI, { "Authorization" => "Bearer acorn-wiki-key" } ], [ wiki.url, wiki.request_headers ]
    assert_no_match "acorn-wiki-key", Workspace::InstallConnector.connection.select_value("SELECT api_key FROM workspace_install_connectors")
  end

  test "where the install has no key, only a workspace with its own may turn the connector on" do
    Rails.application.config.x.install_connectors[:wiki][:api_key] = nil
    assert_not McpServer.turn_on(@acorn, "wiki").persisted?

    @acorn.install_connectors.create!(name: "wiki", url: ACORN_WIKI, api_key: "acorn-wiki-key")
    McpServer.turn_on(@acorn, "wiki")
    InstallConnectorsJob.perform_now
    assert_equal [ ACORN_WIKI ], @acorn.mcp_servers.where(install: "wiki").pluck(:url)
    assert_not McpServer.turn_on(@alice.personal_workspace, "wiki").persisted?
    assert_empty @alice.personal_workspace.mcp_servers.where(install: "wiki")
  end

  test "a changed key lists its tools again; removed, the workspace is back on the install's" do
    own = @acorn.install_connectors.create!(name: "wiki", url: ACORN_WIKI, api_key: "acorn-wiki-key")
    McpServer.turn_on(@acorn, "wiki")
    perform_enqueued_jobs(only: McpServerRefreshJob)
    assert_enqueued_with(job: McpServerRefreshJob) { own.update!(api_key: "acorn-wiki-key-2") }

    own.destroy!
    wiki = @acorn.mcp_servers.find_by!(install: "wiki")
    assert_equal [ WIKI, { "Authorization" => "Bearer install-wiki-key" } ], [ wiki.url, wiki.request_headers ]
  end

  test "an agent's own key still comes first, on its workspace's address" do
    @acorn.install_connectors.create!(name: "wiki", url: ACORN_WIKI, api_key: "acorn-wiki-key")
    own = @acorn.mcp_servers.create!(user: @alice, conversation: @agent.conversation, name: "wiki", install: "wiki", url: ACORN_WIKI, token: "ada-wiki-key")
    assert_equal({ "Authorization" => "Bearer ada-wiki-key" }, own.request_headers)
  end

  test "only the install's connectors, with a key, at a public https address or the install's own host" do
    connectors = @acorn.install_connectors
    assert_not connectors.new(name: "ledger", api_key: "k").valid?, "not one of the install's"
    assert_not connectors.new(name: "wiki").valid?, "no key"
    assert_not connectors.new(name: "wiki", url: "http://wiki.acorn.example.com/mcp", api_key: "k").valid?, "plain http elsewhere"
    assert_not connectors.new(name: "wiki", url: "https://10.0.0.7/mcp", api_key: "k").valid?, "the host's private network"
    assert_not connectors.new(name: "wiki", url: "https://localhost/mcp", api_key: "k").valid?
    assert connectors.new(name: "wiki", url: "http://example-wiki:3000/other", api_key: "k").valid?, "the install's own host"
    assert connectors.new(name: "wiki", url: ACORN_WIKI, api_key: "k").valid?
    connectors.create!(name: "wiki", api_key: "k")
    assert_not connectors.new(name: "wiki", api_key: "k").valid?, "one each"
  end

  # The operator lists other hosts inside the install (CONNECTORS__INTERNAL_HOSTS),
  # such as a second wiki accessory one workspace keeps to itself.
  OWN_WIKI = "http://acorn-wiki:3000/mcp".freeze

  test "a host the operator lists is accepted for a workspace's address, reached over plain http and not pinned" do
    own_wiki = stub_mcp_server(url: OWN_WIKI, tools: [ mcp_tool("search") ])
    listing "acorn-wiki" do
      perform_enqueued_jobs(only: McpServerRefreshJob) do
        @acorn.install_connectors.create!(name: "wiki", url: OWN_WIKI, api_key: "acorn-wiki-key")
        McpServer.turn_on(@acorn, "wiki")
        McpServer.turn_on(@alice.personal_workspace, "wiki")
      end
      assert_requested own_wiki.with(headers: { "Authorization" => "Bearer acorn-wiki-key" }), at_least_times: 1
      assert_equal %w[ search ], @acorn.mcp_servers.find_by!(install: "wiki").tools.pluck("name")

      in_production do
        assert_not @acorn.mcp_servers.find_by!(install: "wiki").pinned?
        personal = @alice.personal_workspace.mcp_servers.find_by!(install: "wiki")
        assert_equal [ WIKI, false ], [ personal.url, personal.pinned? ], "the install's own, as before"
      end
    end
  end

  test "an unlisted internal host is refused, as before" do
    assert_not @acorn.install_connectors.new(name: "wiki", url: OWN_WIKI, api_key: "k").valid?
    listing "other-wiki" do
      assert_not @acorn.install_connectors.new(name: "wiki", url: OWN_WIKI, api_key: "k").valid?
    end
  end

  test "a listed host opens no other private address, by any other name, port or connector" do
    listing "acorn-wiki:3000" do
      connectors = @acorn.install_connectors
      assert connectors.new(name: "wiki", url: OWN_WIKI, api_key: "k").valid?
      [ "http://acorn-wiki:4000/mcp", "http://acorn-wiki/mcp", "http://acorn-wiki.example.com:3000/mcp",
        "http://acorn-wiki@169.254.169.254:3000/mcp", "http://169.254.169.254/latest", "https://169.254.169.254/latest",
        "http://localhost:3000/mcp", "https://localhost/mcp", "http://10.0.0.7:3000/mcp", "https://10.0.0.7/mcp",
        "http://127.0.0.1:3000/mcp" ].each do |url|
        assert_not connectors.new(name: "wiki", url:, api_key: "k").valid?, url
      end

      in_production do
        # A person's own connector gets nothing from the list: still https, and pinned to a public address.
        mine = @acorn.mcp_servers.new(user: @alice, name: "mine", url: OWN_WIKI)
        assert_not mine.valid?
        mine.url = "https://acorn-wiki:3000/mcp"
        assert mine.pinned?
      end
    end
  end

  test "its own address is reached as any person's is, pinned to a public one; the install's inside the host is not" do
    @acorn.install_connectors.create!(name: "wiki", url: ACORN_WIKI, api_key: "acorn-wiki-key")
    [ @acorn, @alice.personal_workspace ].each { McpServer.turn_on(it, "wiki") }
    original, Rails.env = Rails.env, "production"
    assert @acorn.mcp_servers.find_by!(install: "wiki").pinned?
    assert_not @alice.personal_workspace.mcp_servers.find_by!(install: "wiki").pinned?
  ensure
    Rails.env = original
  end

  private
    def listing(hosts)
      x = Rails.application.config.x
      saved, x.connectors = x.connectors, x.connectors.to_h.merge(internal_hosts: hosts)
      yield
    ensure
      x.connectors = saved
    end

    def in_production
      original, Rails.env = Rails.env, "production"
      yield
    ensure
      Rails.env = original
    end
end
