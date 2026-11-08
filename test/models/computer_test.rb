require "test_helper"
require_relative "../test_helpers/agent_test_helper"

class ComputerTest < ActiveSupport::TestCase
  include AgentTestHelper

  setup { @agent = create_user.agents.sole }

  test "an agent without a computer, or with one that is off, sends none; turning one on changes the definition" do
    assert_nil @agent.conversation.definition[:computer]
    off = @agent.conversation.definition[:digest]

    @agent.create_computer!(provider: "local", state: "off")
    assert_nil @agent.reload.conversation.definition[:computer]
    assert_equal off, @agent.conversation.definition[:digest]

    @agent.computer.update!(state: "on")
    assert_equal({ provider: "local", notesFile: true }, @agent.reload.conversation.definition[:computer])
    assert_not_equal off, @agent.conversation.definition[:digest]
  end

  test "the notes file switch is part of the computer the sidecar receives, so turning it off changes the digest" do
    @agent.create_computer!(provider: "local", state: "on")
    on = @agent.conversation.definition[:digest]

    @agent.computer.update!(notes_file: false)

    assert_equal({ provider: "local", notesFile: false }, @agent.reload.conversation.definition[:computer])
    assert_not_equal on, @agent.conversation.definition[:digest]
  end

  test "a sprite name prefix is named after the agent, and the sidecar gets it" do
    computer = @agent.create_computer!(provider: "sprites", state: "on")

    assert_equal "durable-assistants-test-b#{@agent.id}", computer.name
    assert_equal({ provider: "sprites", name: computer.name, notesFile: true }, @agent.reload.conversation.definition[:computer])
  end

  test "a deployment names its Sprites with its own prefix, and a stored name is never rebuilt" do
    computer = with_setting(:pi_durable, :sprite_prefix, "acme") { @agent.create_computer!(provider: "sprites", state: "on") }
    assert_equal "acme-test-b#{@agent.id}", computer.name

    computer.update!(state: "off")
    assert_equal "acme-test-b#{@agent.id}", computer.reload.name
  end

  test "only the kinds this environment offers, and names a Sprite accepts" do
    assert_not @agent.build_computer(provider: "docker").valid?
    assert_not @agent.build_computer(provider: "local", state: "maybe").valid?
    assert_not @agent.build_computer(provider: "sprites", name: "Not A Name").valid?
  end
end
