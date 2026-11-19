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

  # An operator rebuilding the Sprite holds the computer, so nothing the agent
  # does makes a fresh one meanwhile; the sidecar learns it from the computer it receives.
  test "an operator's hold reaches the sidecar in the computer it receives, and releasing it puts it back" do
    computer = @agent.create_computer!(provider: "sprites", state: "on")
    before = @agent.conversation.definition[:digest]

    computer.hold!
    assert computer.reload.held?
    assert_equal({ provider: "sprites", name: computer.name, notesFile: true, held: true }, @agent.reload.conversation.definition[:computer])
    assert_not_equal before, @agent.conversation.definition[:digest]

    computer.release!
    assert_not computer.reload.held?
    assert_nil computer.held_at
    assert_equal({ provider: "sprites", name: computer.name, notesFile: true }, @agent.reload.conversation.definition[:computer])
    assert_equal before, @agent.conversation.definition[:digest]
  end

  test "only the kinds this environment offers, and names a Sprite accepts" do
    assert_not @agent.build_computer(provider: "docker").valid?
    assert_not @agent.build_computer(provider: "local", state: "maybe").valid?
    assert_not @agent.build_computer(provider: "sprites", name: "Not A Name").valid?
  end

  test "over SSH the sidecar gets the machine, the user and the folder, all three needed before it goes on" do
    computer = @agent.create_computer!(provider: "ssh", state: "off", ssh_host: "homeserver")
    assert_nil computer.ssh_address, "filled in one at a time while off"
    assert_not computer.update(state: "on")
    assert_equal [ "Ssh user can't be blank", "Folder can't be blank" ], computer.errors.full_messages

    computer.update!(ssh_user: " jordan ", folder: "/home/jordan/work", state: "on")
    assert_equal "jordan@homeserver:/home/jordan/work", computer.ssh_address
    assert_equal({ provider: "ssh", host: "homeserver", user: "jordan", folder: "/home/jordan/work", keyring: "agent-#{@agent.id}", notesFile: true },
      @agent.reload.conversation.definition[:computer])
  end

  test "each agent's SSH computer uses its own keyring, even two of one person's on one machine; a pinned one keeps its own" do
    @agent.create_computer!(provider: "ssh", state: "on", ssh_host: "homeserver", ssh_user: "alice", folder: "/home/alice")
    another = @agent.user.personal_workspace.agents.create!(Agent.starter(:assistant).merge(user: @agent.user, name: "Robin", email_name: "robin"))
    theirs = another.create_computer!(provider: "ssh", state: "on", ssh_host: "homeserver", ssh_user: "alice", folder: "/home/alice/robin")
    assert_equal [ "agent-#{@agent.id}", "agent-#{another.id}" ], [ @agent.computer.ssh_keyring, theirs.ssh_keyring ]
    assert_equal "agent-#{another.id}", another.reload.conversation.definition.dig(:computer, :keyring)

    theirs.update!(ssh_keyring: "person-#{another.user_id}")
    assert_equal "person-#{another.user_id}", another.reload.conversation.definition.dig(:computer, :keyring), "an existing computer keeps its person's key"
  end

  test "a machine's user that is another person's is refused" do
    @agent.create_computer!(provider: "ssh", state: "on", ssh_host: "homeserver", ssh_user: "alice", folder: "/home/alice")
    bob = create_user(name: "Bob").agents.sole
    computer = bob.build_computer(provider: "ssh", state: "off", ssh_host: "homeserver", ssh_user: "alice")
    assert_not computer.valid?
    assert_equal [ "Ssh user is another person's on homeserver: ask them, or use a user of your own" ], computer.errors.full_messages
    assert bob.build_computer(provider: "ssh", state: "off", ssh_host: "homeserver", ssh_user: "bob").valid?
  end

  test "an SSH computer refuses what the sidecar would: an option for a host, a user that is not one, a folder that climbs out" do
    computer = @agent.create_computer!(provider: "ssh", state: "on", ssh_host: "homeserver", ssh_user: "jordan", folder: "/home/jordan/work")
    { ssh_host: "-oProxyCommand=sh", ssh_user: "Jordan Reyes" }.each do |field, value|
      assert_not computer.update(field => value), field
      computer.reload
    end
    [ "work", "/home/jordan/../root", "/home/jordan\nwork" ].each { assert_not computer.reload.update(folder: it), it }
  end
end
