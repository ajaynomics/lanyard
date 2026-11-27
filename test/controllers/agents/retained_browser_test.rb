require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

# Every agent whose work runs over SSH keeps its Sprite for the screen: the
# shell and files on the SSH machine, the browser and desktop on the Sprite
# (docs/computers.md, "A screen beside SSH").
class Agents::RetainedBrowserTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  setup do
    sign_in_via_ajent
    install_sidecar_settings
    @person = User.find_by!(oidc_sub: "42") # tenancy-ok: signed in above
    @agent = @person.agents.sole
    @thread = @agent.conversation
    @thread.update!(durable_id: "42")
    @ssh = { workspace_id: @agent.workspace_id.to_s, agent_ids: @agent.id.to_s,
             host: "work.example.test", user: "runner", base: "/srv/work", keyring: "configured-review" }
  end

  teardown { remove_sidecar_settings }

  test "an install-managed SSH computer keeps its Sprite for the screen, with no list of agents" do
    settings do
      computer = @agent.create_computer!(provider: "configured_ssh", state: "on")
      granted = assert_retained_screen(computer)
      assert_equal "configured-review", granted.dig("configuredSsh", "keyring")
    end
  end

  test "an agent's own SSH computer, in a workspace that is not its person's own, keeps its Sprite for the screen" do
    team = Workspace.create!(name: "Team")
    team.memberships.create!(user: @person, role: "owner")
    @agent.update!(workspace: team)
    settings do
      computer = @agent.create_computer!(provider: "ssh", state: "on", ssh_host: "homeserver", ssh_user: "jordan", folder: "/home/jordan/work")
      assert_nil assert_retained_screen(computer)["configuredSsh"]
    end
  end

  test "no screen beside SSH while the computer is held, the agent paused, or the install offers no Sprites" do
    computer = nil
    settings do
      computer = @agent.create_computer!(provider: "ssh", state: "on", ssh_host: "homeserver", ssh_user: "jordan", folder: "/home/jordan/work")
      computer.hold!
      assert_no_retained_screen "held"
      computer.release!
      @agent.update!(paused_at: Time.current)
      assert_no_retained_screen "paused", paused: true
      @agent.update!(paused_at: nil)
      computer.update!(state: "off")
      assert_no_retained_screen "off"
    end
    settings(computers: [ "ssh" ]) do
      computer.update!(state: "on")
      assert_no_retained_screen "no Sprites"
    end
  end

  private
    def assert_retained_screen(computer)
      get conversation_path(@thread)
      assert_select "a[href='#{conversation_screen_path(@thread)}']", text: "Open screen"
      assert @thread.reload.screen?
      assert_equal true, @thread.definition.dig(:computer, :retainedBrowser)
      grant
      granted = response.parsed_body
      assert_equal({ "prefix" => computer.name, "conversationId" => "42" }, granted["retainedBrowser"])

      get conversation_screen_path(@thread)
      assert_response :success
      assert_select "form[action='#{conversation_screen_passes_path(@thread)}']", count: 0
      post conversation_screen_passes_path(@thread)
      assert_response :not_found
      granted
    end

    def assert_no_retained_screen(kind, paused: false)
      get conversation_path(@thread)
      assert_select "a[href='#{conversation_screen_path(@thread)}']", { count: 0 }, kind
      get conversation_screen_path(@thread)
      assert_response :not_found, kind
      assert_not @thread.reload.screen?, kind
      assert_nil @thread.definition.dig(:computer, :retainedBrowser), kind
      grant
      assert_equal paused, response.parsed_body["paused"] == true, kind
      assert_nil response.parsed_body["retainedBrowser"], kind
    end

    # As the sidecar asks before it opens the retained screen (agent/runtime.mjs).
    def grant
      post "/agent/accesses", headers: rails_bearer, as: :json,
        params: { actorId: @agent.user_id.to_s, workspaceId: @agent.id.to_s, configuredSsh: true, retainedBrowser: true, conversationId: @thread.durable_id }
    end

    def settings(computers: [ "sprites", "ssh", "configured_ssh" ], &block)
      with_setting(:pi_durable, :computers, computers) do
        with_setting(:pi_durable, :configured_ssh, @ssh, &block)
      end
    end
end
