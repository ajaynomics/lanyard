require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# Where a person finds their workspaces: Settings' Workspaces row, the name of
# the one they work in above the lists, and each one's page, their personal
# one included. Before, a person in only their own saw nothing that led to
# any, and an install that serves one person (ACCESS__OWNER_EMAIL) had no
# way to make one at all.
class WorkspaceEntryPointsTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  OWNER = "operator@example.com".freeze
  APP = { "User-Agent" => "Hotwire Native iOS; Turbo Native iOS; bridge-components: [button]" }.freeze

  setup { install_sidecar_settings }
  teardown do
    remove_sidecar_settings
    OmniAuth.config.mock_auth[:ajent] = nil
  end

  test "Settings lists Workspaces, which lists the person's own first and leads to a new one" do
    sign_in_via_ajent
    bob = signed_in
    household = shared_with(bob, "Household")

    get settings_path
    assert_select ".settings-nav__link[href=?]", workspaces_path, text: "Workspaces"

    get workspaces_path
    assert_response :success
    assert_select "#workspaces a.ui-row", count: 2
    assert_select "#workspaces a.ui-row[href=?]", workspace_path(bob.personal_workspace), text: /Test Operator.*Yours/m
    assert_select "#workspaces a.ui-row[href=?]", workspace_path(household), text: /Household.*2 people/m
    assert_select "a[href=?]", new_workspace_path, text: "New workspace"
  end

  test "personal and shared workspace headings link to the correct workspace, alone or together" do
    sign_in_via_ajent
    bob = signed_in

    get root_path
    assert_select ".agent-group__title a[href=?]", workspace_path(bob.personal_workspace), text: "Yours"
    assert_select ".agent-group", count: 1

    household = shared_with(bob, "Household")
    get root_path
    assert_select ".agent-group", count: 2
    assert_select ".agent-group__title a[href=?]", workspace_path(bob.personal_workspace), text: "Yours"
    assert_select ".agent-group__title a[href=?]", workspace_path(household), text: "Household"
  end

  test "the personal workspace has its page, with the way back, and is renamed there; blank goes back to the person's name" do
    sign_in_via_ajent
    personal = signed_in.personal_workspace

    get workspace_path(personal)
    assert_response :success
    assert_select "h1", "Test Operator"
    assert_select "a[href=?]", workspaces_path, text: /Workspaces/
    assert_select "#billing"

    get edit_workspace_path(personal)
    assert_response :success
    patch workspace_path(personal), params: { workspace: { name: "Home base" } }
    assert_redirected_to workspace_path(personal)
    assert_equal "Home base", personal.reload.name

    patch workspace_path(personal), params: { workspace: { name: "" } }
    assert_nil personal.reload.name
    assert_equal "Test Operator", personal.to_s
  end

  test "a personal workspace's name is kept to 100 characters by the server too, and a refused one is not shown as its name" do
    sign_in_via_ajent
    personal = signed_in.personal_workspace

    patch workspace_path(personal), params: { workspace: { name: "a" * 101 } }
    assert_response :unprocessable_entity
    assert_nil personal.reload.name
    assert_select ".field__error", count: 1, text: /too long/
    assert_select "h1", "Rename Test Operator"
  end

  test "another person's personal workspace is not found" do
    alice = create_user(name: "Alice", email: "member@example.com")
    sign_in_via_ajent

    get workspace_path(alice.personal_workspace)
    assert_response :not_found
    patch workspace_path(alice.personal_workspace), params: { workspace: { name: "Taken" } }
    assert_response :not_found
    assert_nil alice.personal_workspace.reload.name
  end

  test "an install that serves one person still lists, makes and manages workspaces" do
    with_setting(:access, :owner, OWNER) do
      sign_in_via_ajent
      get settings_path
      assert_select ".settings-nav__link[href=?]", workspaces_path

      post workspaces_path, params: { workspace: { name: "Household" } }
      household = signed_in.workspaces.shared.sole
      assert_redirected_to workspace_path(household)
      get workspace_path(household)
      assert_response :success
    end
  end

  test "an install that serves one person refuses to invite, in a plain line on the page and at the door" do
    with_setting(:access, :owner, OWNER) do
      sign_in_via_ajent
      household = shared_with(signed_in, "Household", alone: true)

      get workspace_path(household)
      assert_select "#invitations_refused", text: /Inviting people needs single-owner mode off/
      assert_select "form[action=?]", workspace_invitations_path(household), count: 0

      assert_no_difference -> { household.invitations.count } do
        post workspace_invitations_path(household), params: { invitation: { email: "guest@example.com" } }
      end
      assert_redirected_to workspace_path(household)
      assert_equal "Inviting people needs single-owner mode off.", flash[:alert]
    end
  end

  test "in an install that serves one person, someone only invited cannot sign in as its owner" do
    alice = create_user(name: "Alice", email: "member@example.com")
    household = shared_with(alice, "Household", alone: true)
    household.invitations.create!(email: "guest@example.com", inviter: alice).approve(by: alice)

    with_setting(:access, :owner, OWNER) do
      sign_in_via_ajent(subject: "sub-guest", email: "guest@example.com", name: "Guest")
      assert_equal sign_in_path, path
      assert_nil session[:user_id]
      assert_nil User.find_by(email: "guest@example.com") # tenancy-ok: proves nobody was made for the guest
    end
  end

  test "in an install that serves one person, an invitation is never accepted as its owner" do
    alice = create_user(name: "Alice", email: "member@example.com")
    household = shared_with(alice, "Household", alone: true)
    household.invitations.create!(email: OWNER, inviter: alice).approve(by: alice)

    with_setting(:access, :owner, OWNER) do
      sign_in_via_ajent
      owner = signed_in
      assert_not household.member?(owner), "the owner did not join by signing in"
      assert household.invitations.exists?(email: OWNER), "the invitation waits, unaccepted"
    end
  end

  test "someone signing in as the owner with another email is logged and shown on the owner's page, never silently" do
    output = StringIO.new
    previous = Rails.logger
    Rails.logger = ActiveSupport::BroadcastLogger.new(previous, ActiveSupport::Logger.new(output))
    with_setting(:access, :owner, OWNER) do
      sign_in_via_ajent(subject: "sub-robin", email: "member@example.com", name: "Robin")
      owner = User.find_by!(email: OWNER) # tenancy-ok: the install's one owner
      assert_equal owner.id, session[:user_id]
      assert_match "A different verified email signed in as the install's owner", output.string
      assert_no_match "member@example.com", output.string, "the log names no email"

      get settings_account_path
      assert_select "#owner_sign_ins li", text: /member@example\.com/
    end
  ensure
    Rails.logger = previous
  end

  test "the owner signing in as themselves is not shown as someone else" do
    with_setting(:access, :owner, OWNER) do
      sign_in_via_ajent
      get settings_account_path
      assert_select "#owner_sign_ins li", count: 0
    end
  end

  test "in the phone app, the workspaces open in Settings' sheet, and leaving one closes the sheet on the list" do
    get "/configurations/ios_v3.json"
    sheet = response.parsed_body["rules"].find { it["patterns"].include?("^/workspaces") }
    assert_equal "modal", sheet&.dig("properties", "context"), "Workspaces, a workspace's page and its rename open as Settings does"
    assert_equal response.parsed_body.as_json, JSON.parse(Rails.root.join("ios/Phone/path-configuration.json").read), "the bundled copy matches"

    sign_in_via_ajent
    bob = signed_in
    household = shared_with(create_user(name: "Alice", email: "member@example.com"), "Household", alone: true)
    household.memberships.create!(user: bob, role: "member")

    get workspace_path(household), headers: APP
    assert_equal household.id, session[:workspace_id]

    delete workspace_membership_path(household, household.memberships.find_by!(user: bob)), headers: APP
    assert_redirected_to turbo_refresh_historical_location_url
    assert_not household.member?(bob)
  end

  test "a member opens a shared workspace's page, the one they used last now, and leaves it" do
    sign_in_via_ajent
    bob = signed_in
    household = shared_with(create_user(name: "Alice", email: "member@example.com"), "Household", alone: true)
    membership = household.memberships.create!(user: bob, role: "member")

    get workspace_path(household)
    assert_equal household.id, session[:workspace_id]
    assert_select "button", text: "Work in it", count: 0
    assert_select "form[action=?] button", workspace_membership_path(household, membership), text: "Leave"
  end

  private
    def signed_in = User.find_by!(id: session[:user_id]) # tenancy-ok: test reads the person it signed in

    def shared_with(user, name, alone: false)
      Workspace.create!(name: name).tap do |workspace|
        workspace.memberships.create!(user: user, role: "owner")
        workspace.memberships.create!(user: create_user(name: "Carol", email: "carol@example.com"), role: "member") unless alone
      end
    end
end
