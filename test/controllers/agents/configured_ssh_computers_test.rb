require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

class Agents::ConfiguredSshComputersTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  setup do
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: test reads the person it signed in
    @settings = { workspace_id: @agent.workspace_id.to_s, agent_ids: @agent.id.to_s,
                  host: "work.example.test", user: "runner", base: "/srv/work", keyring: "configured-review" }
  end

  test "the normal Computer resource opts in only the selected agent and never takes targets from the form" do
    with_config do
      get agent_computer_path(@agent)
      assert_select "#computer option[value='configured_ssh']", "Install-managed SSH"
      assert_nil @agent.reload.conversation.definition[:computer]

      @agent.create_computer!(provider: "sprites", state: "on")
      assert_equal "sprites", @agent.reload.conversation.definition.dig(:computer, :provider)
      patch agent_computer_path(@agent), params: { computer: { provider: "configured_ssh", state: "on",
        ssh_host: "wrong.example.test", ssh_user: "wrong", folder: "/wrong", ssh_keyring: "agent-42" } }
      assert_redirected_to agent_computer_path(@agent)
      assert_nil @agent.reload.computer.ssh_host
      assert_equal({ provider: "ssh", host: "work.example.test", user: "runner", folder: "/srv/work/#{@agent.email_name}",
                    keyring: "configured-review", notesFile: true }, @agent.conversation.definition[:computer])
      follow_redirect!
      assert_select "#computer input[name='computer[ssh_host]']", count: 0
      assert_select "#computer", { text: /configured-review/, count: 0 }
      get agent_computer_host_key_path(@agent)
      assert_response :not_found
    end
    assert_nil @agent.reload.conversation.definition[:computer], "removing install config revokes the saved selection"
  end

  test "the private sidecar grant follows the current workspace and selection, not a saved definition" do
    install_sidecar_settings
    scope = { actorId: @agent.user_id.to_s, workspaceId: @agent.id.to_s, configuredSsh: true }
    with_config do
      @agent.create_computer!(provider: "configured_ssh", state: "on")
      post "/agent/accesses", params: scope, headers: rails_bearer, as: :json
      assert_equal @agent.computer.descriptor.slice(:host, :user, :folder, :keyring).stringify_keys, response.parsed_body["configuredSsh"]

      shared = Workspace.make(name: "Family", owner: @agent.user)
      assert @agent.move_to(shared, by: @agent.user)
      post "/agent/accesses", params: scope, headers: rails_bearer, as: :json
      assert_equal true, response.parsed_body["allowed"]
      assert_nil response.parsed_body["configuredSsh"]
      assert_nil @agent.reload.conversation.definition[:computer]
    end
  ensure
    remove_sidecar_settings
  end

  test "shared workspaces and other agents cannot select the kind even with forged parameters" do
    shared = Workspace.make(name: "Family", owner: @agent.user)
    family = shared.agents.create!(Agent.starter(:assistant).merge(user: @agent.user, name: "Family agent", email_name: "family-agent"))
    sibling = @agent.workspace.agents.create!(Agent.starter(:assistant).merge(user: @agent.user, name: "Other agent", email_name: "other-agent"))

    with_config do
      [ family, sibling ].each do |outside|
        get agent_computer_path(outside)
        assert_select "#computer option[value='configured_ssh']", count: 0
        patch agent_computer_path(outside), params: { computer: { provider: "configured_ssh", state: "on" } }
        assert_nil outside.reload.computer
      end
    end
    with_config(@settings.merge(workspace_id: shared.id.to_s, agent_ids: family.id.to_s)) do
      patch agent_computer_path(family), params: { computer: { provider: "configured_ssh", state: "on" } }
      assert_nil family.reload.computer, "even an explicitly named shared workspace is ineligible"
    end
    unrelated = create_user(name: "Unrelated").agents.sole
    with_config(@settings.merge(agent_ids: unrelated.id.to_s)) do
      assert_not unrelated.build_computer(provider: "configured_ssh", state: "on").valid?
    end
  end

  test "unsafe or incomplete config and unsafe stored slugs never reach the descriptor" do
    with_config do
      @agent.create_computer!(provider: "configured_ssh", state: "on")
      assert @agent.reload.conversation.definition[:computer]
    end
    { host: "-oProxyCommand=sh", user: "runner;sh", base: "/srv/../work", keyring: "configured-../shared",
      agent_ids: "*", workspace_id: "" }.each do |field, invalid|
      with_config(@settings.merge(field => invalid)) { assert_nil @agent.reload.conversation.definition[:computer], field }
    end
    with_config do
      @agent.workspace.agents.where(id: @agent.id).update_all(email_name: "../$(unsafe)")
      assert_nil @agent.reload.conversation.definition[:computer]
    end
  end

  # Its folder is named after its address, so a new address would leave the agent's files behind.
  test "its address can't change while its computer is install-managed SSH" do
    with_config do
      @agent.create_computer!(provider: "configured_ssh", state: "on")
      with_setting(:mail, :domain, "agents.example") do
        with_setting(:mail, :smtp_address, "smtp.agents.example") do
          get agent_path(@agent)
          assert_select "#agent_identity input[name='agent[email_name]']", count: 0
          assert_select "#agent_identity .ui-row__value", "assistant@agents.example"
          assert_select "#agent_identity", text: /keeps its address while its computer is install-managed SSH/
        end
      end
      patch agent_email_address_path(@agent), params: { agent: { email_name: "avery" } }
      assert_response :unprocessable_entity
      assert_equal "/srv/work/assistant", @agent.reload.conversation.definition.dig(:computer, :folder)

      @agent.computer.update!(provider: "sprites")
      patch agent_email_address_path(@agent), params: { agent: { email_name: "avery" } }
      assert_equal "avery", @agent.reload.email_name
    end
  end

  private
    def with_config(settings = @settings, &block)
      with_setting(:pi_durable, :computers, Computer.providers + [ "configured_ssh" ]) do
        with_setting(:pi_durable, :configured_ssh, settings, &block)
      end
    end
end
