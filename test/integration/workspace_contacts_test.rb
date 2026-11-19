require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# A shared workspace's members page: each member chooses the one agent that
# alone may contact them, and the owner keeps the list of which agent answers
# which outside contact. A member sees the list but cannot change it, and
# nobody reaches either through another workspace or another's agent.
class WorkspaceContactsTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  setup do
    install_sidecar_settings
    sign_in_via_ajent(name: "Olive")
    @owner = User.find_by!(oidc_sub: "42") # tenancy-ok: test reads the person it signed in
    post workspaces_path, params: { workspace: { name: "Harbour" } }
    @harbour = @owner.workspaces.find_by!(name: "Harbour")
    @ada = @owner.start_agent("Ada", workspace: @harbour, email_name: "ada")
    @bo = @owner.start_agent("Bo", workspace: @harbour, email_name: "bo")
    @client = create_user(name: "Quinn", email: "quinn@example.com")
    @quinns = @harbour.memberships.create!(user: @client, role: "member")
    @elsewhere = @client.personal_workspace.agents.sole
  end
  teardown { remove_sidecar_settings }

  test "the owner routes a contact to an agent, sees it listed, and removes it" do
    get workspace_path(@harbour)
    assert_select "h2", "Contact routing"
    assert_equal @harbour.agents.order(:name).map(&:name), css_select("form[action='#{workspace_contact_routes_path(@harbour)}'] select option:not([value=''])").map(&:text)
    assert_not_includes css_select("select option").map(&:text), @elsewhere.name

    post workspace_contact_routes_path(@harbour), params: { contact_route: { contact: "Client@Example.net", agent_id: @ada.id } }
    assert_redirected_to workspace_path(@harbour)
    route = @harbour.contact_routes.sole
    assert_equal [ "client@example.net", @ada ], [ route.contact, route.agent ]
    follow_redirect!
    assert_select "#contact_routes li", text: /client@example\.net\s*Answered by Ada/

    post workspace_contact_routes_path(@harbour), params: { contact_route: { contact: "416 555 0199", agent_id: @bo.id } }
    assert_equal "4165550199", @harbour.contact_routes.find_by!(agent: @bo).contact
    get workspace_path(@harbour)
    assert_select "#contact_routes li", text: /\(416\) 555-0199/

    post workspace_contact_routes_path(@harbour), params: { contact_route: { contact: "client@example.net", agent_id: @bo.id } }
    assert_response :unprocessable_entity
    assert_select ".field__error", /already routed/
    post workspace_contact_routes_path(@harbour), params: { contact_route: { contact: "lee@example.net", agent_id: @elsewhere.id } }
    assert_response :unprocessable_entity, "another workspace's agent is no choice"

    delete workspace_contact_route_path(@harbour, route)
    assert_redirected_to workspace_path(@harbour)
    assert_not Workspace::ContactRoute.exists?(route.id)
  end

  test "a member sees the routing but cannot change it" do
    route = @harbour.contact_routes.create!(contact: "client@example.net", agent: @ada)
    sign_in_via_ajent(subject: "sub-quinn", email: "quinn@example.com", name: "Quinn")
    get workspace_path(@harbour)
    assert_select "#contact_routes li", text: /client@example\.net/
    assert_select "form[action='#{workspace_contact_routes_path(@harbour)}']", count: 0
    assert_select "button", text: "Remove", count: 0

    post workspace_contact_routes_path(@harbour), params: { contact_route: { contact: "lee@example.net", agent_id: @ada.id } }
    assert_response :not_found
    delete workspace_contact_route_path(@harbour, route)
    assert_response :not_found
    assert_equal [ route ], @harbour.contact_routes.to_a
  end

  test "a member chooses the one agent that contacts them, and their number; then any again" do
    sign_in_via_ajent(subject: "sub-quinn", email: "quinn@example.com", name: "Quinn")
    get workspace_path(@harbour)
    assert_select "h2", "Who contacts you"
    assert_select "select#membership_sole_contact_id option[selected]", count: 0
    assert_select "select#membership_sole_contact_id option", text: "Any of its agents"

    patch workspace_sole_contact_path(@harbour), params: { membership: { sole_contact_id: @ada.id, phone_number: "+1 (416) 555-0111" } }
    assert_redirected_to workspace_path(@harbour)
    assert_equal [ @ada, "4165550111" ], [ @quinns.reload.sole_contact, @quinns.phone_number ]
    follow_redirect!
    assert_select "select#membership_sole_contact_id option[selected]", text: "Ada"
    assert_select "input#membership_phone_number[value='(416) 555-0111']"
    assert_nil @owner.memberships.find_by!(workspace: @harbour).sole_contact, "only their own choice changes"

    patch workspace_sole_contact_path(@harbour), params: { membership: { sole_contact_id: @elsewhere.id, phone_number: "" } }
    assert_redirected_to workspace_path(@harbour)
    assert_equal [ nil, nil ], [ @quinns.reload.sole_contact, @quinns.phone_number ], "another workspace's agent is no choice: any again"

    patch workspace_sole_contact_path(@harbour), params: { membership: { sole_contact_id: @bo.id, phone_number: "12" } }
    assert_response :unprocessable_entity
    assert_select ".field__error", /ten-digit/
    assert_nil @quinns.reload.sole_contact
  end

  test "neither is reached in a workspace the person is not in" do
    other = Workspace.create!(name: "Cove").tap { it.memberships.create!(user: @client, role: "owner") }
    patch workspace_sole_contact_path(other), params: { membership: { sole_contact_id: "" } }
    assert_response :not_found
    post workspace_contact_routes_path(other), params: { contact_route: { contact: "lee@example.net", agent_id: @ada.id } }
    assert_response :not_found
    assert_empty other.contact_routes
  end
end
