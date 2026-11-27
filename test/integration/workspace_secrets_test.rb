require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/passbolt_test_helper"

# A shared workspace's own vault user and install connector keys, on its page
# (docs/design/workspaces.md, sections 2.2, 2.4 and 2.6). Its owner sets and
# removes them; a member sees only whether each is set; nobody is shown one.
class WorkspaceSecretsTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include PassboltTestHelper
  include ActiveJob::TestHelper

  KEY = "-----BEGIN PGP PRIVATE KEY BLOCK-----\nhousehold-made-up\n-----END PGP PRIVATE KEY BLOCK-----".freeze
  PASS = "household-made-up-passphrase".freeze
  WIKI_KEY = "household-wiki-key-made-up".freeze

  setup do
    install_sidecar_settings
    install_fake_passbolt
    @previous = Rails.application.config.x.install_connectors
    Rails.application.config.x.install_connectors = {
      wiki: { url: "http://example-wiki:3000/mcp", api_key: "install-wiki-key", tools: %w[ search ] },
      crm: { url: "http://example-crm:3000/mcp", tools: %w[ find_* ], loaded: false }
    }
    stub_request(:post, %r{\Ahttps?://(example-wiki|example-crm|wiki\.household\.example\.com)}).to_return(status: 503)
    sign_in_via_ajent(name: "Olive")
    @owner = User.find_by!(oidc_sub: "42") # tenancy-ok: test reads the person it signed in
    @bob = create_user(name: "Bob")
    @household = Workspace.create!(name: "Household")
    @household.memberships.create!(user: @owner, role: "owner")
    @household.memberships.create!(user: @bob, role: "member")
  end
  teardown do
    Rails.application.config.x.install_connectors = @previous
    remove_fake_passbolt
    remove_sidecar_settings
  end

  test "the owner gives the workspace its own vault user, sees only that it is set, and removes it" do
    get workspace_path(@household)
    assert_select "#vault_user", text: /The install's/
    get edit_workspace_vault_user_path(@household)
    assert_response :success

    patch workspace_vault_user_path(@household), params: { vault_user: { private_key: KEY, passphrase: "" } }
    assert_response :unprocessable_entity
    assert_not @household.reload.vault_user?

    patch workspace_vault_user_path(@household), params: { vault_user: { private_key: KEY, passphrase: PASS } }
    assert_redirected_to workspace_path(@household)
    assert_equal [ KEY, PASS ], [ @household.reload.passbolt_private_key, @household.passbolt_passphrase ]
    follow_redirect!
    assert_select "#vault_user", text: /Its own/
    get edit_workspace_vault_user_path(@household)
    [ "household-made-up", PASS ].each { assert_no_match it, response.body }

    delete workspace_vault_user_path(@household)
    assert_redirected_to workspace_path(@household)
    assert_not @household.reload.vault_user?
  end

  test "the owner gives the workspace its own vault server with its user, and only an https one" do
    patch workspace_vault_user_path(@household), params: { vault_user: { url: "http://vault.example.test", private_key: KEY, passphrase: PASS } }
    assert_response :unprocessable_entity
    assert_select ".field__error", text: /Server must start with https/
    assert_nil @household.reload.passbolt_url

    patch workspace_vault_user_path(@household), params: { vault_user: { url: "https://vault.example.test", private_key: KEY, passphrase: PASS } }
    assert_redirected_to workspace_path(@household)
    assert_equal "https://vault.example.test", @household.reload.passbolt_url
    follow_redirect!
    assert_select "#vault_user", text: /own server at vault\.example\.test/

    delete workspace_vault_user_path(@household)
    assert_nil @household.reload.passbolt_url
  end

  test "a refused save on a workspace with no user yet shows none set, and asks for the key and passphrase again" do
    [ "http://vault.example.test", "https://10.0.0.5" ].each do |url|
      patch workspace_vault_user_path(@household), params: { vault_user: { url:, private_key: KEY, passphrase: PASS } }
      assert_response :unprocessable_entity
      assert_no_match "Its own is set", response.body
      assert_select "button", text: "Remove its own user", count: 0
      assert_select ".field__error", text: /paste the private key and passphrase again/i
      [ "household-made-up", PASS ].each { assert_no_match it, response.body }
    end

    @household.update!(passbolt_private_key: KEY, passbolt_passphrase: PASS)
    patch workspace_vault_user_path(@household), params: { vault_user: { url: "http://vault.example.test", private_key: KEY, passphrase: PASS } }
    assert_match "Its own is set", response.body
    assert_select "button", text: "Remove its own user"
  end

  # Olive is the office's owner, so the household, hers, falls back on the install's key.
  test "the owner gives the workspace its own wiki key and address, sees only that it is set, and removes it" do
    with_setting(:office, :owner_email, "operator@example.com") do
      McpServer.turn_on(@household, "wiki")
      get workspace_path(@household)
      assert_select "#install_connector_wiki", text: /The install's/
      assert_select "#install_connector_crm", text: /None/

      get edit_workspace_install_connector_path(@household, "wiki")
      assert_response :success
      patch workspace_install_connector_path(@household, "wiki"), params: { install_connector: { url: "http://wiki.household.example.com/mcp", api_key: WIKI_KEY } }
      assert_response :unprocessable_entity
      assert_select ".field__error", text: /https/

      patch workspace_install_connector_path(@household, "wiki"), params: { install_connector: { url: "https://wiki.household.example.com/mcp", api_key: WIKI_KEY } }
      assert_redirected_to workspace_path(@household)
      assert_equal [ "https://wiki.household.example.com/mcp", WIKI_KEY ], @household.install_connectors.reload.sole.then { [ it.url, it.api_key ] }
      assert_equal "https://wiki.household.example.com/mcp", @household.mcp_servers.find_by!(install: "wiki").url
      follow_redirect!
      assert_select "#install_connector_wiki", text: /Its own/
      get edit_workspace_install_connector_path(@household, "wiki")
      assert_no_match WIKI_KEY, response.body

      delete workspace_install_connector_path(@household, "wiki")
      assert_redirected_to workspace_path(@household)
      assert_empty @household.install_connectors.reload
      assert_equal "http://example-wiki:3000/mcp", @household.mcp_servers.find_by!(install: "wiki").url
    end
  end

  test "a member sees whether each is set, and can neither set, change nor remove one" do
    @household.update!(passbolt_private_key: KEY, passbolt_passphrase: PASS)
    @household.install_connectors.create!(name: "wiki", api_key: WIKI_KEY)
    sign_in_via_ajent(subject: "sub-bob", email: "bob@example.com", name: "Bob")

    get workspace_path(@household)
    assert_response :success
    assert_select "#vault_user", text: /Its own/
    assert_select "#install_connector_wiki", text: /Its own/
    assert_select "a[href='#{edit_workspace_vault_user_path(@household)}']", count: 0
    assert_select "a[href='#{edit_workspace_install_connector_path(@household, "wiki")}']", count: 0
    [ "household-made-up", PASS, WIKI_KEY ].each { assert_no_match it, response.body }

    get edit_workspace_vault_user_path(@household)
    assert_response :not_found
    patch workspace_vault_user_path(@household), params: { vault_user: { private_key: "x", passphrase: "y" } }
    assert_response :not_found
    delete workspace_vault_user_path(@household)
    assert_response :not_found
    get edit_workspace_install_connector_path(@household, "wiki")
    assert_response :not_found
    patch workspace_install_connector_path(@household, "wiki"), params: { install_connector: { api_key: "mine" } }
    assert_response :not_found
    delete workspace_install_connector_path(@household, "wiki")
    assert_response :not_found

    assert_equal [ KEY, PASS ], [ @household.reload.passbolt_private_key, @household.passbolt_passphrase ]
    assert_equal WIKI_KEY, @household.install_connectors.sole.api_key
  end

  test "only the install's connectors have a page" do
    get edit_workspace_install_connector_path(@household, "ledger")
    assert_response :not_found
  end
end
