require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/voipms_test_helper"

# A shared workspace's own voip.ms account (docs/phone.md), named by its owner
# alone on the workspace's page as a vault entry, never the password itself.
class WorkspaceVoipmsAccountTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include VoipmsTestHelper

  setup do
    install_voipms_settings
    sign_in_via_ajent(name: "Owner")
    @owner = User.find_by!(oidc_sub: "42") # tenancy-ok: test reads the person it signed in
    create_user(name: "Bob", email: "member@example.com")
    @workspace = Workspace.make(name: "Pilot", owner: @owner)
    @workspace.memberships.create!(user: User.find_by!(email: "member@example.com"), role: "member") # tenancy-ok: test reads the member it made
    get workspace_path(@workspace)
  end

  teardown { remove_voipms_settings }

  test "the owner names the workspace's voip.ms account by its vault entry; the password is never asked for or shown" do
    get workspace_path(@workspace)
    assert_select "#voipms_account", /the install's voip\.ms account/
    assert_select "#voipms_account input[name='workspace[voipms_vault_entry]']"
    assert_select "#voipms_account input[type=password]", count: 0

    patch workspace_voipms_account_path(@workspace), params: { workspace: { voipms_vault_entry: "  Pilot   voip.ms " } }
    assert_redirected_to workspace_path(@workspace)
    assert_equal "Pilot voip.ms", @workspace.reload.voipms_vault_entry
    follow_redirect!
    assert_select "#voipms_account", /its own voip\.ms account, saved in the password manager as Pilot voip\.ms/
    assert_not_includes response.body, "synthetic-api-password"

    patch workspace_voipms_account_path(@workspace), params: { workspace: { voipms_vault_entry: "x" * 201 } }
    assert_response :unprocessable_entity
    assert_equal "Pilot voip.ms", @workspace.reload.voipms_vault_entry

    delete workspace_voipms_account_path(@workspace)
    assert_redirected_to workspace_path(@workspace)
    assert_nil @workspace.reload.voipms_vault_entry, "without one, the install's as before"
  end

  test "a member sees that the workspace has its own account, not the entry's name, and can neither name nor remove one" do
    @workspace.update!(voipms_vault_entry: "Pilot voip.ms")
    sign_in_via_ajent(subject: "sub-bob", email: "member@example.com", name: "Bob")
    get workspace_path(@workspace)

    get workspace_path(@workspace)
    assert_response :success
    assert_select "#voipms_account", /its own voip\.ms account/
    assert_select "#voipms_account form", count: 0
    assert_not_includes response.body, "Pilot voip.ms", "the entry's name is the owner's, as Campfire's is"
    patch workspace_voipms_account_path(@workspace), params: { workspace: { voipms_vault_entry: "Elsewhere" } }
    assert_response :not_found
    delete workspace_voipms_account_path(@workspace)
    assert_response :not_found
    assert_equal "Pilot voip.ms", @workspace.reload.voipms_vault_entry
  end
end
