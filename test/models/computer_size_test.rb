require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# How big an agent's Sprite is made (Computer::Size): the agent's own size,
# else its workspace's, else the install's default, which is what every
# Sprite was made with before sizes were settings; never past the install's maximum.
class ComputerSizeTest < ActiveSupport::TestCase
  include AgentTestHelper

  setup do
    @agent = create_user.agents.sole
    @workspace = @agent.workspace
  end

  test "without any setting, a Sprite is exactly today's size, and the sidecar is sent no size" do
    computer = @agent.create_computer!(provider: "sprites", state: "on")

    assert_equal Computer::Size.new(cpus: 2, memory_mib: 2048, disk_mib: 8192), computer.size
    assert_equal({ provider: "sprites", name: computer.name, notesFile: true }, @agent.reload.conversation.definition[:computer])
  end

  test "a new computer gets its workspace's size" do
    @workspace.update!(computer_cpus: 1, computer_memory_mib: 1024)
    computer = @agent.create_computer!(provider: "sprites", state: "on")

    assert_equal Computer::Size.new(cpus: 1, memory_mib: 1024, disk_mib: 8192), computer.size
    assert_equal({ provider: "sprites", name: computer.name, notesFile: true, size: { cpus: 1, memoryMib: 1024, diskMib: 8192 } },
      @agent.reload.conversation.definition[:computer])
  end

  test "an agent's own size overrides its workspace's, part by part" do
    with_setting(:pi_durable, :computer_maximum, { cpus: 8, memory_mib: 16_384, disk_mib: 65_536 }) do
      @workspace.update!(computer_cpus: 4, computer_memory_mib: 8192)
      computer = @agent.create_computer!(provider: "sprites", state: "on", memory_mib: 16_384, disk_mib: 32_768)

      assert_equal Computer::Size.new(cpus: 4, memory_mib: 16_384, disk_mib: 32_768), computer.size
      assert_equal({ cpus: 4, memoryMib: 16_384, diskMib: 32_768 }, @agent.reload.conversation.definition[:computer][:size])
    end
  end

  test "a size over the install's maximum is refused, saying the most it allows" do
    computer = @agent.create_computer!(provider: "sprites", state: "on")

    assert_not computer.update(memory_mib: 4096)
    assert_equal [ "Memory can be at most 2 GiB on this install" ], computer.errors.full_messages
    assert_not @workspace.update(computer_cpus: 4, computer_disk_mib: 16_384)
    assert_equal [ "CPUs can be at most 2 on this install", "Disk can be at most 8 GiB on this install" ], @workspace.errors.full_messages

    with_setting(:pi_durable, :computer_maximum, { memory_mib: 4096 }) do
      assert computer.update(memory_mib: 4096)
      assert_not computer.update(memory_mib: 8192)
      assert_equal [ "Memory can be at most 4 GiB on this install" ], computer.errors.full_messages
    end
  end

  test "none of a part is refused" do
    assert_not @workspace.update(computer_cpus: 0)
    assert_equal [ "CPUs must be at least 1" ], @workspace.errors.full_messages
  end

  # An install that lowers its maximum keeps what was saved, and makes no Sprite bigger than it now allows.
  test "a saved size over a lowered maximum is made at the maximum" do
    computer = with_setting(:pi_durable, :computer_maximum, { memory_mib: 8192 }) do
      @agent.create_computer!(provider: "sprites", state: "on", memory_mib: 8192)
    end

    assert_equal 2048, computer.reload.size.memory_mib
  end

  # The screen opens before the agent's first message too, so it may be what makes the Sprite.
  test "opening the screen asks for the agent's size, and for none at the install's default" do
    @agent.create_computer!(provider: "sprites", state: "on")
    asked = []
    original = DurableAssistants::PiDurable::Client.instance_method(:screen)
    DurableAssistants::PiDurable::Client.define_method(:screen) { |_access, _id, computer:, size: nil, &_block| asked << [ computer, size ] }

    @agent.conversation.screen { }
    @workspace.update!(computer_cpus: 1)
    @agent.reload.conversation.screen { }

    assert_equal [ [ @agent.computer.name, nil ], [ @agent.computer.name, "1,2048,8192" ] ], asked
  ensure
    DurableAssistants::PiDurable::Client.define_method(:screen, original)
  end

  test "only a Sprite has a size for the sidecar" do
    @workspace.update!(computer_cpus: 1)
    @agent.create_computer!(provider: "local", state: "on")

    assert_equal({ provider: "local", notesFile: true }, @agent.reload.conversation.definition[:computer])
  end
end
