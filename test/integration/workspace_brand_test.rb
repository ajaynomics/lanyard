require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/email_test_helper"

# A workspace may go by its own name, colour and link host (docs/deployments.md,
# "A workspace's own name, colour and link host"; issue #229). Its owner sets
# the name and colour on its page; the link host only the install's operator
# does, in a console. Its pages show its name and colour, and the links in its
# people's mail go to its host. A workspace that sets none is as before: the
# install's APP__NAME, APP__ACCENT_HUE and APP__URL.
class WorkspaceBrandTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include EmailTestHelper

  LINK_HOST = "office.example.net".freeze

  setup do
    install_sidecar_settings
    install_email_settings
    sign_in_via_ajent(name: "Owner")
    @owner = User.find_by!(oidc_sub: "42") # tenancy-ok: test reads the person it signed in
    @personal = @owner.personal_workspace
    @field = Workspace.make(name: "Field", owner: @owner)
    @agent = @field.agents.create!(user: @owner, name: "Scout", instructions: "Help.", model: Agent.models.first)
    @own_agent = @personal.agents.first || @personal.agents.create!(user: @owner, name: "Mine", instructions: "Help.", model: Agent.models.first)
  end

  teardown do
    remove_email_settings
    remove_sidecar_settings
  end

  test "its owner sets its name and colour on its page, and its pages show them; their other workspace is untouched" do
    get workspace_path(@field)
    assert_select "#brand input[name='workspace[app_name]'][maxlength='40']"
    assert_select "#brand select[name='workspace[accent_hue]'] option[value='']", text: /The install's/
    assert_select "#brand [name='workspace[link_host]']", count: 0

    with_setting(:app, :redirects, LINK_HOST) do
      patch workspace_brand_path(@field), params: { workspace: { app_name: " Field  Office ", accent_hue: "150", link_host: LINK_HOST } }
    end
    assert_redirected_to workspace_path(@field)
    assert_equal [ "Field Office", 150, nil ], @field.reload.values_at(:app_name, :accent_hue, :link_host), "the link host is the operator's alone"

    get workspace_path(@field)
    get root_path
    assert_select ".app-header__brand", text: "Field Office"
    get workspace_path(@field)
    assert_select "title", text: /Field Office/
    assert_select "head style[data-turbo-track=dynamic]", text: /--accent-hue: 150;/
    assert_select "#brand input[name='workspace[app_name]'][value='Field Office']"
    assert_select "#brand select[name='workspace[accent_hue]'] option[selected][value='150']"

    assert_equal [ nil, nil, nil ], @personal.reload.values_at(:app_name, :accent_hue, :link_host)
    get workspace_path(@personal)
    get root_path
    assert_select ".app-header__brand", text: "Durable Assistants"
    assert_select "head style[data-turbo-track=dynamic]", text: /--accent-hue: 255;/

    patch workspace_brand_path(@field), params: { workspace: { app_name: "", accent_hue: "" } }
    assert_equal [ nil, nil ], @field.reload.values_at(:app_name, :accent_hue), "blank is the install's again"
  end

  test "a member sees them but no form, and cannot set them" do
    @field.update!(app_name: "Field Office", accent_hue: 150)
    member = create_user(name: "Bob", email: "member@example.com")
    @field.memberships.create!(user: member, role: "member")

    sign_in_via_ajent(subject: "sub-bob", email: "member@example.com", name: "Bob")
    get workspace_path(@field)
    assert_response :success
    assert_select "#brand", /Field Office/
    assert_select "#brand form", count: 0

    patch workspace_brand_path(@field), params: { workspace: { app_name: "Bob's", accent_hue: "10" } }
    assert_response :not_found
    assert_equal [ "Field Office", 150 ], @field.reload.values_at(:app_name, :accent_hue)
  end

  test "an overlong name or a colour that is no hue is refused, saying why" do
    patch workspace_brand_path(@field), params: { workspace: { app_name: "x" * 41, accent_hue: "150" } }
    assert_response :unprocessable_entity
    assert_select "#brand .field__error", text: "Name is too long (maximum is 40 characters)"

    patch workspace_brand_path(@field), params: { workspace: { app_name: "Field Office", accent_hue: "400" } }
    assert_response :unprocessable_entity
    assert_select "#brand .field__error", text: "Colour must be a hue from 0 to 360"

    assert_equal [ nil, nil ], @field.reload.values_at(:app_name, :accent_hue)
  end

  test "a workspace's notice that its agent needs someone links to its own host; another workspace's is unchanged" do
    with_setting(:app, :redirects, LINK_HOST) do
      @field.update!(link_host: LINK_HOST)

      field = AgentMailer.needs_you(@agent.conversation, to: "owner@example.com", title: "Scout needs you", body: "Allow?").deliver_now
      assert_match %r{Answer it here: http://#{Regexp.escape(LINK_HOST)}/conversations/#{@agent.conversation.id}\n}, field.body.to_s

      own = AgentMailer.needs_you(@own_agent.conversation, to: "owner@example.com", title: "Mine needs you", body: "Allow?").deliver_now
      assert_match %r{Answer it here: http://example\.com/conversations/#{@own_agent.conversation.id}\n}, own.body.to_s
    end
  end

  test "an invitation to a workspace links to its own host" do
    with_setting(:app, :redirects, LINK_HOST) do
      @field.update!(link_host: LINK_HOST)
      invitation = @field.invitations.create!(email: "guest@example.com", inviter: @owner)

      assert_match %r{http://#{Regexp.escape(LINK_HOST)}/workspaces/#{@field.id}\n}, WorkspaceMailer.invitation(invitation).deliver_now.body.to_s
    end
  end

  test "its name and colour show on its pages, and the install's on another's, as the person switches between them" do
    @field.update!(app_name: "Field Office", accent_hue: 150)

    get workspace_path(@field)
    get root_path
    assert_select ".app-header__brand", text: "Field Office"
    assert_select ".app-header__brand img[src=?]", "/icons/favicon.svg?hue=150"
    assert_select "title", text: /Field Office/
    assert_select "head style[data-turbo-track=dynamic]", text: /--accent-hue: 150;/

    get workspace_path(@personal)
    get root_path
    assert_select ".app-header__brand", text: "Durable Assistants"
    assert_select ".app-header__brand img[src=?]", "/icons/favicon.svg"
    assert_select "head style[data-turbo-track=dynamic]", text: /--accent-hue: 255;/
  end

  test "renaming the workspace sets none of them" do
    patch workspace_path(@field), params: { workspace: { name: "Field", app_name: "Mine now", accent_hue: 10, link_host: "evil.example.com" } }

    assert_equal [ nil, nil, nil ], @field.reload.values_at(:app_name, :accent_hue, :link_host)
  end

  test "the installed app keeps the install's name" do
    @field.update!(app_name: "Field Office")
    get workspace_path(@field)

    get pwa_manifest_path(format: :json)
    assert_equal "Durable Assistants", response.parsed_body["name"]
  end
end
