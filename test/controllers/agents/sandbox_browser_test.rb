require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

class Agents::SandboxBrowserTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  setup do
    sign_in_via_ajent
    install_sidecar_settings
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: signed in above
    @thread = @agent.conversation
    @thread.update!(durable_id: "42")
    @ssh = { workspace_id: @agent.workspace_id.to_s, agent_ids: @agent.id.to_s,
             host: "work.example.test", user: "runner", base: "/srv/work", keyring: "configured-review" }
    @scope = { actorId: @agent.user_id.to_s, workspaceId: @agent.id.to_s,
               configuredSsh: true, sandboxBrowser: true, conversationId: @thread.durable_id }
  end

  teardown { remove_sidecar_settings }

  test "only the live scope of a mapped managed SSH computer receives its exact sandbox browser" do
    settings do
      computer = @agent.create_computer!(provider: "configured_ssh", state: "on")
      assert_equal true, @thread.definition.dig(:computer, :sandboxBrowser)
      assert_not @thread.reload.screen?, "sandbox drive does not add a viewer"
      grant(name: "another", browser: "another", tabId: "another")
      assert_response :success
      assert_equal({ "name" => "avery", "conversationId" => "42",
                     "ssh" => computer.descriptor.slice(:host, :user, :folder, :keyring).stringify_keys }, response.parsed_body["sandboxBrowser"])

      grant(sandboxBrowser: false)
      assert_nil response.parsed_body["sandboxBrowser"]
      grant(conversationId: "4353")
      assert_response :not_found

      computer.hold!
      grant
      assert_response :success
      assert_nil response.parsed_body["sandboxBrowser"]
      assert_nil @thread.reload.definition.dig(:computer, :sandboxBrowser)
    end
  end

  test "ambiguous or revoked names cannot grant a sandbox browser" do
    settings do
      @agent.create_computer!(provider: "configured_ssh", state: "on")
      [ "", "#{@agent.id}=avery,999=avery", "#{@agent.id}=avery,#{@agent.id}=another" ].each do |names|
        with_setting(:pi_durable, :sandbox_browsers, names) do
          grant
          assert_response :success
          assert_nil response.parsed_body["sandboxBrowser"]
        end
      end
    end
  end

  test "ordinary SSH binds the existing SSH account without granting configured SSH" do
    settings do
      computer = @agent.create_computer!(provider: "ssh", state: "on", ssh_host: "work.example.test", ssh_user: "runner", folder: "/srv/work/avery")
      grant(configuredSsh: false)
      assert_response :success
      assert_equal true, @thread.definition.dig(:computer, :sandboxBrowser)
      assert_equal computer.ssh_keyring, response.parsed_body.dig("sandboxBrowser", "ssh", "keyring")
      assert_nil response.parsed_body["configuredSsh"]
    end
  end

  private
    def grant(**changes)
      post "/agent/accesses", params: @scope.merge(changes), headers: rails_bearer, as: :json
    end

    def settings(&block)
      with_setting(:pi_durable, :computers, %w[ configured_ssh ssh ]) do
        with_setting(:pi_durable, :configured_ssh, @ssh) do
          with_setting(:pi_durable, :sandbox_browsers, "#{@agent.id}=avery", &block)
        end
      end
    end
end
