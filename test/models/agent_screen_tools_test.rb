require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/passbolt_test_helper"

# Every built-in tool whose answer the sidecar takes to the screen's browser
# (Tool.on_screen?) is offered only where the agent's computer has a screen
# (Computer#screen?): its Sprite, or the Sprite an SSH computer keeps for the
# screen (docs/computers.md, "A screen beside SSH"); or the agent's own browser on the host (Agent#screen?).
class AgentScreenToolsTest < ActiveSupport::TestCase
  include AgentTestHelper
  include PassboltTestHelper

  setup do
    install_fake_passbolt
    @agent = create_user(name: "Avery").agents.sole
    @agent.update!(tool_names: (SCREEN_TOOLS & Tool::Catalog::TOOLS.values).map(&:tool_name))
    @ssh = { workspace_id: @agent.workspace_id.to_s, agent_ids: @agent.id.to_s,
             host: "work.example.test", user: "runner", base: "/srv/work", keyring: "configured-review" }
  end
  teardown { remove_fake_passbolt }

  # What the sidecar takes to the screen: a fill (agent/sign-in.mjs) or a card (agent/card.mjs).
  SCREEN_TOOLS = Tool::Catalog.built_ins.select { it.fills? || it.pays? }.freeze

  test "the catalogue names its screen tools, and the rule knows each" do
    assert SCREEN_TOOLS.all?(&:on_screen?)
    assert_includes SCREEN_TOOLS, Tool::SignInWithSavedPassword
    assert_includes SCREEN_TOOLS, Tool::PayByCard
  end

  test "only an agent with a screen has the screen tools" do
    settings do
      assert_screen_tools false, "no computer"
      @agent.create_computer!(provider: "configured_ssh", state: "on")
      assert_screen_tools true, "configured SSH, which keeps its Sprite for the screen"
      @agent.computer.hold!
      assert_screen_tools false, "a held retained browser"
      @agent.computer.update!(provider: "sprites", held_at: nil)
      assert_screen_tools true, "a Sprite"
      @agent.computer.update!(state: "off")
      assert_screen_tools false, "a Sprite that is off"
    end
  end

  test "a retained browser has what signing in needs, not the outside link, which needs no screen" do
    settings do
      @agent.create_computer!(provider: "configured_ssh", state: "on")
      names = @agent.reload.available_own_tools.map(&:tool_name)
      assert_includes names, "list_saved_sign_ins"
      assert_includes names, "sign_in_with_saved_password"
      assert_includes names, "ask_for_sign_in"
      assert_not_includes names, "ask_outside_for_sign_in"
    end
  end

  test "an agent's own browser on the host is a screen for signing in, with no Sprite, not the outside link and no card" do
    @agent.create_computer!(provider: "local", state: "on")
    settings do
      with_setting(:pi_durable, :sandbox_browsers, "#{@agent.id}=avery") do
        [ "a computer with no screen", "no computer" ].each do |kind|
          names = @agent.reload.available_own_tools.map(&:tool_name)
          assert_includes names, "sign_in_with_saved_password", kind
          assert_not_includes names, "ask_outside_for_sign_in", kind
          assert_not_includes names, "pay_by_card", kind
          @agent.computer&.destroy!
        end
      end
    end
  end

  private
    def assert_screen_tools(expected, kind)
      offered = @agent.reload.available_own_tools & SCREEN_TOOLS
      expected ? assert_equal(SCREEN_TOOLS.sort_by(&:tool_name), offered.sort_by(&:tool_name), kind) : assert_empty(offered, kind)
    end

    def settings(&block)
      with_setting(:link, :client_id, "link-client") do
        with_setting(:pi_durable, :computers, %w[ sprites configured_ssh ]) do
          with_setting(:pi_durable, :configured_ssh, @ssh, &block)
        end
      end
    end
end
