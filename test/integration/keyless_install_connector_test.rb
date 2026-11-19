require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/mcp_test_helper"

# An install's connector with no key of the install's own (one whose agents
# each act as themselves, say). In a workspace the install's owner doesn't
# own it is not the install's key being kept from it: there is none. A key of
# the workspace's own still makes it work there, so it stays listed with Set
# its own key, said as something it doesn't have yet rather than a refusal (#241).
class KeylessInstallConnectorTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include McpTestHelper
  include ActiveJob::TestHelper

  WIKI = "http://example-wiki:3000/mcp".freeze
  DOCS = "http://example-docs:3000/mcp".freeze
  KEPT = "The install's key is only for its owner's workspaces".freeze
  NOT_YET = "It works here once this workspace has a key of its own.".freeze
  NO_INSTALL_KEY = "The install has no key for it, so it works here once this workspace has one of its own.".freeze

  setup do
    @previous = Rails.application.config.x.install_connectors
    Rails.application.config.x.install_connectors = {
      wiki: { url: WIKI, api_key: "install-wiki-key", tools: %w[ search ] },
      harbor_docs: { url: DOCS, tools: %w[ search ] }
    }
    stub_mcp_server(url: WIKI, tools: [ mcp_tool("search") ])
    stub_mcp_server(url: DOCS, tools: [ mcp_tool("search") ])
    @operator = create_user(name: "Operator", email: "operator@example.com")
    @member = create_user(name: "Member")
  end
  teardown { Rails.application.config.x.install_connectors = @previous }

  test "another owner's workspace lists it as one it can have with its own key, not as the install's key kept from it" do
    with_setting(:office, :owner_email, "operator@example.com") do
      sign_in_via_ajent(subject: "sub-member", email: "member@example.com", name: "Member")
      personal = @member.personal_workspace

      get connectors_path
      assert_select "#office_connector_harbor_docs", text: /Off\. #{Regexp.escape(NOT_YET)}/
      assert_select "#office_connector_harbor_docs", text: /#{KEPT}/, count: 0
      assert_select "#office_connector_harbor_docs a[href='#{edit_workspace_install_connector_path(personal, "harbor_docs")}']", text: "Set its own key"
      # The wiki's install key exists and is kept from Olive: that is still what it says.
      assert_select "#office_connector_wiki", text: /#{KEPT}; this one needs its own\./

      get workspace_path(personal)
      assert_select "#install_connector_harbor_docs", text: /None yet\. #{Regexp.escape(NOT_YET)}/
      assert_select "#install_connector_harbor_docs", text: /#{KEPT}/i, count: 0
      assert_select "#install_connector_wiki", text: /None: #{KEPT}/i

      get edit_workspace_install_connector_path(personal, "harbor_docs")
      assert_select "p", text: /The install has no key of its own for harbor_docs/
      assert_no_match KEPT, response.body
    end
  end

  test "its own key makes it work in another owner's workspace, which is why it stays listed" do
    with_setting(:office, :owner_email, "operator@example.com") do
      personal = @member.personal_workspace
      refused = McpServer.turn_on(personal, "harbor_docs")
      assert_equal [ "harbor_docs needs this workspace's own key: the install has none of its own" ], refused.errors.full_messages
      assert_match "the install's is only for the install owner's workspaces", McpServer.turn_on(personal, "wiki").errors.full_messages.to_sentence

      personal.install_connectors.create!(name: "harbor_docs", api_key: "member-docs-key-made-up")
      docs = perform_enqueued_jobs { McpServer.turn_on(personal, "harbor_docs") }
      assert docs.persisted? && docs.enabled?
      assert_equal [ DOCS, { "Authorization" => "Bearer member-docs-key-made-up" } ], [ docs.url, docs.request_headers ]
    end
  end

  # The install's owner's own workspace would use the install's key, but there is none to use, so it too needs its own.
  test "the install owner's own workspace says the install has no key for it, and a sweep changes nothing there" do
    with_setting(:office, :owner_email, "operator@example.com") do
      sign_in_via_ajent(subject: "sub-operator", email: "operator@example.com", name: "Operator")
      personal = @operator.personal_workspace
      2.times { InstallConnectorsJob.perform_now }
      assert_empty personal.mcp_servers.where.not(install: nil)

      get connectors_path
      assert_select "#office_connector_harbor_docs", text: /Off\. #{Regexp.escape(NO_INSTALL_KEY)}/
      assert_select "#office_connector_harbor_docs", text: /#{KEPT}/, count: 0
      assert_select "#office_connector_harbor_docs a[href='#{edit_workspace_install_connector_path(personal, "harbor_docs")}']", text: "Set its own key"
      assert_select "#office_connector_wiki button", text: "Turn on"

      get workspace_path(personal)
      assert_select "#install_connector_harbor_docs", text: /None yet\. #{Regexp.escape(NO_INSTALL_KEY)}/
      assert_select "#install_connector_harbor_docs", text: /#{KEPT}/i, count: 0
      assert_select "#install_connector_wiki", text: /The install's key/

      get edit_workspace_install_connector_path(personal, "harbor_docs")
      assert_select "p", text: /The install has no key of its own for harbor_docs/
      assert_select "p", text: /they use the install's/, count: 0
    end
  end
end
