require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

class Agents::ComputersControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  setup do
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: test reads the person it signed in
  end

  test "the person turns their agent's computer on and off from its settings" do
    get agent_path(@agent)
    assert_select "#computer", /Off/

    patch agent_computer_path(@agent), params: { computer: { provider: "local", state: "on" } }
    assert_redirected_to agent_path(@agent)
    assert @agent.reload.computer.on?
    follow_redirect!
    assert_select "#computer", /On: This machine/

    patch agent_computer_path(@agent), params: { computer: { provider: "local", state: "off" } }
    assert_not @agent.reload.computer.on?
    assert_nil @agent.conversation.definition[:computer]
  end

  test "the notes file is read unless the person turns it off" do
    get agent_path(@agent)
    assert_select "#computer label", text: /Notes file \(AGENTS\.md\)\s*Read at the start of each reply, up to 32 KB\./
    assert_select "#computer input[type=checkbox][name='computer[notes_file]'][checked]"

    patch agent_computer_path(@agent), params: { computer: { provider: "local", state: "on", notes_file: "0" } }
    assert_not @agent.reload.computer.notes_file
    assert_equal({ provider: "local", notesFile: false }, @agent.conversation.definition[:computer])
  end

  test "a kind this environment does not offer is refused" do
    patch agent_computer_path(@agent), params: { computer: { provider: "docker", state: "on" } }

    assert_redirected_to agent_path(@agent)
    assert_nil @agent.reload.computer
    assert_match(/Provider/, flash[:alert])
  end

  test "someone else's agent is not found" do
    other = create_user(name: "Other").agents.sole

    patch agent_computer_path(other), params: { computer: { provider: "local", state: "on" } }

    assert_response :not_found
    assert_nil other.reload.computer
  end
end
