require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# The size of an agent's Sprite, set as settings: the workspace's owner sets
# its default on its members page and each agent's own on its Computer page;
# a member sees the size in use there and changes neither.
class ComputerSizesTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  setup do
    install_sidecar_settings
    sign_in_via_ajent(name: "Owner")
    @owner = User.find_by!(oidc_sub: "42") # tenancy-ok: test reads the person it signed in
    post workspaces_path, params: { workspace: { name: "Household" } }
    @workspace = @owner.workspaces.find_by!(name: "Household")
    @agent = @workspace.agents.create!(user: @owner, name: "Shared", instructions: "Help.", model: Agent.models.first)
    @agent.create_computer!(provider: "sprites", state: "on")
    @member = create_user(name: "Member", email: "member@example.com")
    @workspace.memberships.create!(user: @member, role: "member")
  end
  teardown { remove_sidecar_settings }

  test "the owner sets the workspace's default size, and its agents' Sprites are made with it" do
    get workspace_path(@workspace)
    assert_select "#computer_size", /Each new conversation's computer: 2 CPUs, 2 GiB memory, 8 GiB disk/

    patch workspace_computer_size_path(@workspace), params: { workspace: { computer_cpus: "1", computer_memory_mib: "1024", computer_disk_mib: "" } }
    assert_redirected_to workspace_path(@workspace)
    assert_equal [ 1, 1024, nil ], @workspace.reload.values_at(:computer_cpus, :computer_memory_mib, :computer_disk_mib)
    assert_equal({ cpus: 1, memoryMib: 1024, diskMib: 8192 }, @agent.reload.conversation.definition[:computer][:size])
    follow_redirect!
    assert_select "#computer_size", /1 CPU, 1 GiB memory, 8 GiB disk/
  end

  test "over the install's maximum is refused, with the most it allows" do
    patch workspace_computer_size_path(@workspace), params: { workspace: { computer_memory_mib: "4096" } }

    assert_response :unprocessable_entity
    assert_select "#computer_size p.field__error", text: "Memory can be at most 2 GiB on this install"
    assert_select "#computer_size", /Each new conversation's computer: 2 CPUs, 2 GiB memory, 8 GiB disk/, "what is in use, not what was refused"
    assert_nil @workspace.reload.computer_memory_mib
  end

  test "the agent's Computer page shows the size in use and where it comes from, and the owner sets the agent's own" do
    with_setting(:pi_durable, :computer_maximum, { memory_mib: 8192 }) do
      @workspace.update!(computer_memory_mib: 4096)
      get agent_computer_path(@agent)
      assert_select "#computer_size", /2 CPUs, 4 GiB memory, 8 GiB disk/
      assert_select "#computer_size select[name='computer[memory_mib]'] option[selected]", /Workspace's \(4 GiB\)/
      assert_select "#computer_size", /made from now on/
      assert_select "#computer_size", /an operator remakes it/

      patch agent_computer_size_path(@agent), params: { computer: { memory_mib: "8192" } }
      assert_redirected_to agent_computer_path(@agent)
      assert_equal 8192, @agent.computer.reload.memory_mib
      assert_equal({ cpus: 2, memoryMib: 8192, diskMib: 8192 }, @agent.reload.conversation.definition[:computer][:size])

      patch agent_computer_size_path(@agent), params: { computer: { memory_mib: "16384" } }
      assert_redirected_to agent_computer_path(@agent)
      assert_equal "Memory can be at most 8 GiB on this install", flash[:alert]
      assert_equal 8192, @agent.computer.reload.memory_mib
    end
  end

  test "a member sees the size in use but changes neither the workspace's nor the agent's" do
    sign_in_via_ajent(name: "Member", subject: "sub-member", email: "member@example.com")
    get workspace_path(@workspace)

    get agent_computer_path(@agent)
    assert_select "#computer_size", /2 CPUs, 2 GiB memory, 8 GiB disk/
    assert_select "#computer_size select", false
    patch agent_computer_size_path(@agent), params: { computer: { cpus: "1" } }
    assert_response :not_found
    assert_nil @agent.computer.reload.cpus

    get workspace_path(@workspace)
    assert_select "#computer_size select", false
    patch workspace_computer_size_path(@workspace), params: { workspace: { computer_cpus: "1" } }
    assert_response :not_found
    assert_nil @workspace.reload.computer_cpus
  end

  test "an install without Sprites shows no size" do
    with_setting(:pi_durable, :computers, %w[ local ]) do
      @agent.computer.update_columns(provider: "local")
      get workspace_path(@workspace)
      assert_select "#computer_size", false
      get agent_computer_path(@agent)
      assert_select "#computer_size", false
    end
  end
end
