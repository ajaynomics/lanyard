require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/mcp_test_helper"

# Files are saved on whatever computer the agent has (Agent#saves_files?),
# not only on a Sprite: an install-managed SSH computer keeps a connector's
# long answer whole, as a Sprite does (agent/files.mjs writes it there).
class ConfiguredSshFileSavesTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include McpTestHelper
  include ActiveJob::TestHelper

  LONG = ("Line of a long answer. " * 9_000).freeze

  setup do
    install_sidecar_settings
    @agent = create_user(name: "Avery").agents.sole
    @conversation = create_conversation(@agent)
  end
  teardown { remove_sidecar_settings }

  test "a connector's answer over the limit is saved whole on a configured SSH computer" do
    make_core(@agent, create_mcp_server(@agent, name: "records", tools: [ mcp_tool("search", annotations: { readOnlyHint: true }) ]))
    stub_mcp_server(calls: { "search" => ->(_) { { content: [ { type: "text", text: LONG } ] } } })
    configured_ssh do
      @agent.create_computer!(provider: "configured_ssh", state: "on")
      invoke
      perform_enqueued_jobs(only: InvocationCallJob)
      done = invoke

      assert_equal true, done["file"]
      assert_equal [ "search-answer.txt" ], done.dig("result", "found_files").pluck("name")
      assert_match "the whole answer is saved on your computer", done.dig("result", "note")
    end
  end

  test "every kind of computer that is on saves files" do
    configured_ssh do
      Computer::LABELS.each_key do |kind|
        computer = @agent.build_computer(provider: kind, state: "on", ssh_host: "box.example.test", ssh_user: "jordan", folder: "/srv/jordan")
        assert @agent.saves_files?, kind
        computer.state = "off"
        assert_not @agent.saves_files?, "#{kind} off"
      end
    end
  end

  private
    def configured_ssh(&block)
      with_setting(:pi_durable, :computers, %w[ local sprites ssh configured_ssh ]) do
        with_setting(:pi_durable, :configured_ssh, { workspace_id: @agent.workspace_id.to_s, agent_ids: @agent.id.to_s,
          host: "work.example.test", user: "runner", base: "/srv/work", keyring: "configured-review" }, &block)
      end
    end

    def invoke
      post "/agent/invocations", params: invocation_payload(@conversation, tool: "mcp__records__search", arguments: {}, call_id: "toolu_1"),
        headers: rails_bearer, as: :json
      response.parsed_body
    end
end
