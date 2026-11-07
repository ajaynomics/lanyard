require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

class Bots::ComputersControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  setup do
    sign_in_via_ajent
    @bot = User.find_by!(oidc_sub: "42").bots.sole # tenancy-ok: test reads the person it signed in
  end

  test "the person turns their bot's computer on and off from its settings" do
    get bot_path(@bot)
    assert_select "#computer", /Off/

    patch bot_computer_path(@bot), params: { computer: { provider: "local", state: "on" } }
    assert_redirected_to bot_path(@bot)
    assert @bot.reload.computer.on?
    follow_redirect!
    assert_select "#computer", /On: This machine/

    patch bot_computer_path(@bot), params: { computer: { provider: "local", state: "off" } }
    assert_not @bot.reload.computer.on?
    assert_nil @bot.definition[:computer]
  end

  test "the notes file is read unless the person turns it off" do
    get bot_path(@bot)
    assert_select "#computer label", text: /Notes file \(AGENTS\.md\)\s*Read at the start of each reply, up to 32 KB\./
    assert_select "#computer input[type=checkbox][name='computer[notes_file]'][checked]"

    patch bot_computer_path(@bot), params: { computer: { provider: "local", state: "on", notes_file: "0" } }
    assert_not @bot.reload.computer.notes_file
    assert_equal({ provider: "local", notesFile: false }, @bot.definition[:computer])
  end

  test "a kind this environment does not offer is refused" do
    patch bot_computer_path(@bot), params: { computer: { provider: "docker", state: "on" } }

    assert_redirected_to bot_path(@bot)
    assert_nil @bot.reload.computer
    assert_match(/Provider/, flash[:alert])
  end

  test "someone else's bot is not found" do
    other = create_user(name: "Other").bots.sole

    patch bot_computer_path(other), params: { computer: { provider: "local", state: "on" } }

    assert_response :not_found
    assert_nil other.reload.computer
  end
end
