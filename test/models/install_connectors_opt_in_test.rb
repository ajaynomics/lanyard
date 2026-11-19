require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/mcp_test_helper"

# An office connector is in a workspace only once its owner, or the office's
# owner (OFFICE__OWNER_EMAIL), turns it on, and the install's own key is used
# only in the office owner's workspaces; any other needs its own (#168).
class InstallConnectorsOptInTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include McpTestHelper
  include ActiveJob::TestHelper

  WIKI = "http://example-wiki:3000/mcp".freeze
  ACORN_WIKI = "https://wiki.acorn.example.com/mcp".freeze

  setup do
    @previous = Rails.application.config.x.install_connectors
    Rails.application.config.x.install_connectors = { wiki: { url: WIKI, api_key: "install-wiki-key", tools: %w[ search ] } }
    stub_mcp_server(url: WIKI, tools: [ mcp_tool("search") ])
    stub_mcp_server(url: ACORN_WIKI, tools: [ mcp_tool("search") ])
    # operator@example.com is the test install's admin; the office has no owner (OFFICE__OWNER_EMAIL) unless a test says so.
    @operator = create_user(name: "Operator", email: "operator@example.com")
    @member = create_user(name: "Member", email: "member@example.com")
  end
  teardown { Rails.application.config.x.install_connectors = @previous }

  test "a member's personal workspace gets no office connector until it is turned on, and then only with its own key" do
    2.times { InstallConnectorsJob.perform_now }
    personal = @member.personal_workspace
    assert_empty personal.mcp_servers.where.not(install: nil)

    refused = McpServer.turn_on(personal, "wiki")
    assert_not refused.persisted?
    assert_match "needs this workspace's own key", refused.errors.full_messages.to_sentence
    assert_empty personal.mcp_servers.reload.where.not(install: nil)

    personal.install_connectors.create!(name: "wiki", url: ACORN_WIKI, api_key: "member-wiki-key")
    assert_empty personal.mcp_servers.reload.where.not(install: nil), "a key alone turns nothing on"
    wiki = McpServer.turn_on(personal, "wiki")
    assert wiki.persisted? && wiki.enabled?
    assert_equal [ ACORN_WIKI, { "Authorization" => "Bearer member-wiki-key" } ], [ wiki.url, wiki.request_headers ]
    InstallConnectorsJob.perform_now
    assert wiki.reload.enabled?
  end

  test "an imported workspace gets none, whoever owns it" do
    with_setting(:office, :owner_email, "operator@example.com") do
      [ @member, @operator ].each do |owner|
        imported = Workspace.make(name: "Imported from #{owner}", owner: owner)
        imported.create_import!(source_digest: "digest-#{owner.id}", source_version: "1")
        2.times { InstallConnectorsJob.perform_now }
        assert_empty imported.mcp_servers.where.not(install: nil), owner.to_s
      end
    end
  end

  test "the install owner's workspace keeps its own on the install's key, and turns on more with it" do
    with_setting(:office, :owner_email, "operator@example.com") do
      personal = @operator.personal_workspace
      wiki = installed(personal)
      2.times { InstallConnectorsJob.perform_now }
      assert wiki.reload.enabled?
      assert_equal({ "Authorization" => "Bearer install-wiki-key" }, wiki.request_headers)

      household = Workspace.make(name: "Household", owner: @operator)
      household.memberships.create!(user: @member, role: "member")
      on = McpServer.turn_on(household, "wiki")
      assert on.persisted? && on.enabled?
      assert_equal({ "Authorization" => "Bearer install-wiki-key" }, on.request_headers)
    end
  end

  test "an existing one in a workspace the install owner doesn't own is switched off, not deleted, once, with a log line" do
    personal = @member.personal_workspace
    acorn = Workspace.make(name: "Acorn", owner: @member)
    acorn.install_connectors.create!(name: "wiki", api_key: "acorn-wiki-key")
    stale, own_key = installed(personal), installed(acorn)

    log = capture_log { 2.times { InstallConnectorsJob.perform_now } }

    assert McpServer.exists?(stale.id), "kept" # tenancy-ok: proves it survived
    assert_not stale.reload.enabled?
    assert_empty stale.request_headers, "never the install's key"
    assert own_key.reload.enabled?, "one on its workspace's own key stays on"
    assert_equal 1, log.scan(/Switched off office connector wiki .*workspace #{personal.id}/).size
  end

  test "a disabled one stays off, wherever it is" do
    wiki = installed(@operator.personal_workspace)
    wiki.update!(enabled: false)
    2.times { InstallConnectorsJob.perform_now }
    assert_not wiki.reload.enabled?
  end

  test "only the workspace's owner or the install's owner turns one on from the Connectors page" do
    household = Workspace.make(name: "Household", owner: @member)
    household.memberships.create!(user: @operator, role: "member")
    household.install_connectors.create!(name: "wiki", api_key: "household-wiki-key")
    outsider = User.create!(oidc_sub: "sub-outsider", email: "outsider@example.com", name: "Outsider")
    household.memberships.create!(user: outsider, role: "member")

    sign_in_via_ajent(subject: "sub-outsider", email: "outsider@example.com", name: "Outsider")
    get workspace_path(household)
    get connectors_path
    assert_select "#office_connector_wiki"
    assert_select "#office_connector_wiki button", count: 0
    post office_connectors_path, params: { name: "wiki" }
    assert_response :not_found
    assert_empty household.mcp_servers.where(install: "wiki")

    with_setting(:office, :owner_email, "operator@example.com") do
      sign_in_via_ajent(subject: "sub-operator", email: "operator@example.com", name: "Operator")
      get workspace_path(household)
      get connectors_path
      assert_select "#office_connector_wiki button", text: "Turn on"
      post office_connectors_path, params: { name: "wiki" }
      wiki = household.mcp_servers.find_by!(install: "wiki")
      assert_redirected_to connector_path(wiki)
      assert_equal({ "Authorization" => "Bearer household-wiki-key" }, wiki.request_headers)
    end
  end

  test "any member switches one off; only the workspace's owner or the install's switches it back on" do
    household = Workspace.make(name: "Household", owner: @member)
    household.install_connectors.create!(name: "wiki", api_key: "household-wiki-key")
    outsider = User.create!(oidc_sub: "sub-outsider", email: "outsider@example.com", name: "Outsider")
    household.memberships.create!(user: outsider, role: "member")
    wiki = McpServer.turn_on(household, "wiki")

    sign_in_via_ajent(subject: "sub-outsider", email: "outsider@example.com", name: "Outsider")
    get workspace_path(household)
    patch connector_path(wiki), params: { connector: { enabled: false } }
    assert_not wiki.reload.enabled?
    patch connector_path(wiki), params: { connector: { enabled: true } }
    assert_not wiki.reload.enabled?
    assert_equal "Only Member or the install's owner turns wiki on.", flash[:alert]

    sign_in_via_ajent(subject: "sub-member", email: "member@example.com", name: "Member")
    get workspace_path(household)
    patch connector_path(wiki), params: { connector: { enabled: true } }
    assert wiki.reload.enabled?
  end

  # The office's owner is OFFICE__OWNER_EMAIL alone: an admin manages the model
  # accounts and invitations, but the install's keys reach what they reach (a
  # CRM, say) only for that one person.
  test "with no office owner, an admin's workspace gets no shared key, and the admin turns none on elsewhere" do
    assert @operator.admin?
    personal = @operator.personal_workspace
    stale = installed(personal)
    2.times { InstallConnectorsJob.perform_now }
    assert_not stale.reload.enabled?
    assert_empty stale.request_headers, "never the install's key"
    refused = McpServer.turn_on(Workspace.make(name: "Desk", owner: @operator), "wiki")
    assert_not refused.persisted?
    assert_match "needs this workspace's own key", refused.errors.full_messages.to_sentence

    household = Workspace.make(name: "Household", owner: @member)
    household.memberships.create!(user: @operator, role: "member")
    household.install_connectors.create!(name: "wiki", api_key: "household-wiki-key")
    sign_in_via_ajent(subject: "sub-operator", email: "operator@example.com", name: "Operator")
    get workspace_path(household)
    get connectors_path
    assert_select "#office_connector_wiki button", count: 0
    post office_connectors_path, params: { name: "wiki" }
    assert_response :not_found
    assert_empty household.mcp_servers.where(install: "wiki")
  end

  # ACCESS__OWNER_EMAIL is the person a one-person install signs everyone in
  # as; it says nothing of whose workspaces use the office's keys.
  test "with no office owner, the person the install serves gets no shared key either" do
    with_setting(:access, :owner, "member@example.com") do
      stale = installed(@member.personal_workspace)
      2.times { InstallConnectorsJob.perform_now }
      assert_not stale.reload.enabled?
      assert_empty stale.request_headers
      assert_not McpServer.turn_on(Workspace.make(name: "Desk", owner: @member), "wiki").persisted?
    end
  end

  test "with the office owner set, that person's workspaces keep the shared key, and an admin who isn't them gets none" do
    with_setting(:office, :owner_email, "member@example.com") do
      kept, household = installed(@member.personal_workspace), Workspace.make(name: "Household", owner: @member)
      dropped = installed(@operator.personal_workspace)
      2.times { InstallConnectorsJob.perform_now }
      assert kept.reload.enabled?
      assert_equal({ "Authorization" => "Bearer install-wiki-key" }, kept.request_headers)
      assert_equal({ "Authorization" => "Bearer install-wiki-key" }, McpServer.turn_on(household, "wiki").request_headers)
      assert_not dropped.reload.enabled?
      assert_empty dropped.request_headers
    end
  end

  test "the office owner matches whatever the case and spaces, of the setting or of the person's email" do
    with_setting(:office, :owner_email, " Member@Example.COM ") do
      assert_equal({ "Authorization" => "Bearer install-wiki-key" }, McpServer.turn_on(@member.personal_workspace, "wiki").request_headers)
    end

    shouting = create_user(name: "Shouting", email: "Shouting@Example.COM")
    with_setting(:office, :owner_email, "shouting@example.com") do
      assert_equal({ "Authorization" => "Bearer install-wiki-key" }, McpServer.turn_on(shouting.personal_workspace, "wiki").request_headers)
      assert_not McpServer.turn_on(Workspace.make(name: "Desk", owner: @member), "wiki").persisted?
    end
  end

  # Naming the office's owner must not make a multi-person install a one-person
  # one: ACCESS__OWNER_EMAIL alone does that (User.sign_in!, Admission.invited?).
  test "the office owner changes nobody's sign-in, admission or invitations" do
    with_setting(:office, :owner_email, "operator@example.com") do
      assert_nil Admission.owner
      member = User.sign_in!(sub: "sub-member-own", email: "member@example.com", name: "Member")
      outsider = User.sign_in!(sub: "sub-outsider-own", email: "outsider@example.com", name: "Outsider")
      assert_equal [ "member@example.com", "outsider@example.com" ], [ member.email, outsider.email ]
      assert_not_equal @operator, member

      household = Workspace.make(name: "Household", owner: @member)
      invitation = household.invitations.create!(email: "guest@example.com", inviter: @member)
      assert invitation.persisted?, invitation.errors.full_messages.to_sentence
      invitation.approve(by: @operator)
      assert Admission.admits?("guest@example.com"), "an invited person is still let in"
    end
  end

  private
    # As an earlier release made one in every workspace, at sign-in or every ten minutes.
    def installed(workspace)
      workspace.mcp_servers.find_by(install: "wiki") ||
        workspace.mcp_servers.new(user: workspace.owner, name: "wiki", install: "wiki", url: WIKI).tap { it.save!(validate: false) }
    end

    def capture_log
      output = StringIO.new
      previous, Rails.logger = Rails.logger, ActiveSupport::Logger.new(output)
      yield
      output.string
    ensure
      Rails.logger = previous
    end
end
