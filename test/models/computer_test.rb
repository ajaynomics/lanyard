require "test_helper"
require_relative "../test_helpers/agent_test_helper"

class ComputerTest < ActiveSupport::TestCase
  include AgentTestHelper

  setup { @bot = create_user.bots.sole }

  test "a bot without a computer, or with one that is off, sends none; turning one on changes the definition" do
    assert_nil @bot.definition[:computer]
    off = @bot.definition[:digest]

    @bot.create_computer!(provider: "local", state: "off")
    assert_nil @bot.reload.definition[:computer]
    assert_equal off, @bot.definition[:digest]

    @bot.computer.update!(state: "on")
    assert_equal({ provider: "local" }, @bot.reload.definition[:computer])
    assert_not_equal off, @bot.definition[:digest]
  end

  test "a sprite is named after the bot, and the sidecar gets the name" do
    computer = @bot.create_computer!(provider: "sprites", state: "on")

    assert_equal "avery-test-bot-#{@bot.id}", computer.name
    assert_equal({ provider: "sprites", name: computer.name }, @bot.reload.definition[:computer])
  end

  test "only the kinds this environment offers, and names a Sprite accepts" do
    assert_not @bot.build_computer(provider: "docker").valid?
    assert_not @bot.build_computer(provider: "local", state: "maybe").valid?
    assert_not @bot.build_computer(provider: "sprites", name: "Not A Name").valid?
  end
end
