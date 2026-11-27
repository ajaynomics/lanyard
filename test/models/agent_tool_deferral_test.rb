require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/mcp_test_helper"
require_relative "../test_helpers/passbolt_test_helper"

# #116: an agent's tools may outgrow its declaration budget. A small core is
# declared in every message (Tool::Catalog::CORE); everything else, rare
# built-ins and connectors alike, is looked up: the model finds it with the
# sidecar's tool_search and calls it by name, asking as any tool does.
class AgentToolDeferralTest < ActiveSupport::TestCase
  include AgentTestHelper
  include McpTestHelper
  include PassboltTestHelper
  include ActiveJob::TestHelper

  setup do
    @alice = create_user(name: "Alice")
    @agent = @alice.agents.sole
    @conversation = create_conversation(@agent)
  end

  test "an agent that wants 65 tools or more still answers, with the same tools every turn, and nothing out of reach" do
    install_sidecar_settings
    sent = []
    # The sidecar still has 64 slots; Rails leaves it room to load more.
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").to_return do |request|
      definition = JSON.parse(request.body)["definition"]
      sent << definition
      count = definition["tools"].size + @agent.sidecar_tool_names.size
      count += @agent.lookup_sidecar_tool_names.size if definition["lookup"].present?
      count > 64 ? { status: 422, body: { error: "tool_limit" }.to_json } : { status: 202, body: { id: sent.size }.to_json }
    end
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/12}).to_return(body: { entries: [], cursor: 0, more: false, status: "running", pendingInputs: [] }.to_json)
    # As a deploy leaves it: pinned without the save's check, past the limit.
    big = @agent.workspace.mcp_servers.new(user: @alice, name: "crm", url: "https://crm.example.com/mcp", refreshed_at: Time.current,
      tools: Array.new(Agent::TOOL_LIMIT) { { "name" => "tool_#{it}", "description" => "Tool #{it}.", "input_schema" => { "type" => "object" } } })
    big.save!(validate: false)
    @agent.core_connectors.new(mcp_server: big).save!(validate: false)

    assert @agent.reload.update(instructions: "Help with the accounts."), @agent.errors.full_messages.to_sentence
    install_fake_passbolt(name: "Desk bot", uri: "https://api.telegram.org", password: "123456789:AAFakeTokenForTests_only-0123456789abcd")
    @agent.create_telegram_bot!(vault_entry: "Desk bot", username: "desk_example_bot")
    Tool::Catalog.names.each { assert @agent.switch_tool(it, true), "#{it}: #{@agent.errors.full_messages.to_sentence}" }
    assert_operator @agent.wanted_tool_count(@conversation.connectors), :>, Agent::TOOL_LIMIT

    @conversation.reload.submit("Any news?", request_id: "m-1")
    @conversation.reload.submit("And now?", request_id: "m-2")

    assert_equal 2, sent.size
    assert_operator sent.last["tools"].size, :<=, Agent::TOOL_LIMIT
    assert_equal sent.first["digest"], sent.last["digest"], "the same tools, in the same order, every turn"
    wanted = (@agent.own_tools + big.tool_classes).map(&:tool_name)
    assert_empty wanted.reject { @conversation.tool(it) }, "every tool it wants is declared or looked up"
    looked_up = @conversation.lookup_tools.map(&:tool_name)
    assert_includes looked_up, "mcp__crm__tool_#{Agent::TOOL_LIMIT - 1}", "the pinned connector's last tools are looked up first"
    # Built-ins come first and spill last, so a core one (telegram_send among
    # them) is never looked up.
    core = @agent.own_tools.map(&:tool_name) & Tool::Catalog::CORE
    assert_includes core, "telegram_send"
    assert_equal core.sort, (core & sent.last["tools"].pluck("name")).sort, "every core built-in stays declared past the limit"
    assert_empty core & looked_up
  ensure
    remove_sidecar_settings
    remove_fake_passbolt
  end

  test "the core list is declared in every message, and the rarer built-ins are looked up" do
    names = @conversation.tools.map(&:tool_name)

    assert_empty Tool::Catalog::CORE & %w[ change_yourself add_routine list_routines remove_routine make_agent join_concourse pay_by_card ]
    assert_includes names, "current_time"
    assert_includes names, "write_document"
    assert_empty names & %w[ find_tools use_tool ], "tool_search finds the rest"
    assert_empty names & %w[ change_yourself add_routine list_routines remove_routine ], "rare: looked up"
    assert_empty names - Tool::Catalog::CORE, "nothing else declared"
    assert_empty Tool::Catalog::CALENDAR.map(&:tool_name) - Tool::Catalog::CORE, "the agent's own calendar and tasks, used every day"
    assert_empty %w[ change_yourself add_routine list_routines remove_routine ] - @conversation.definition[:lookup].pluck(:name),
      "tool_search and a script's searchTools() find them"
  end

  test "a looked-up built-in called by its own name asks as it does declared, and runs once allowed" do
    routine = { "schedule" => "every weekday at 8am", "prompt" => "Brief me on the day." }
    with_setting(:app, :approve_everything, true) do
      assert_equal "waiting", receive("add_routine", routine)[:status], "asks even where the install approves everything"
    end
    asked = @conversation.invocations.sole
    assert_equal :approval, asked.asks
    assert_match(/routine/i, asked.card_title)

    asked.approve!(by: @alice)
    receive("add_routine", routine)
    perform_enqueued_jobs only: InvocationCallJob
    assert_equal "succeeded", asked.reload.state, asked.error
    assert_equal [ "Brief me on the day." ], @agent.routines.pluck(:prompt)
  end

  # Nothing stands between the model and a looked-up tool any more, so nothing
  # can carry a call past the tool's own questions.
  test "find_tools and use_tool are no longer its tools: a call to either is refused" do
    change = { "instructions" => "Every agent signs off with its name.", "scope" => "workspace" }
    assert receive("use_tool", "name" => "change_yourself", "arguments" => change)[:isError]
    assert receive("find_tools", "query" => "change my instructions")[:isError]
    assert_empty @conversation.invocations.where(state: :awaiting_person)
  end

  private
    def receive(tool, arguments)
      call_id = "toolu_#{Digest::SHA256.hexdigest([ tool, arguments ].to_json).first(12)}"
      payload = invocation_payload(@conversation, tool: tool, arguments: arguments, call_id: call_id)
      Invocation.receive(@conversation, task_id: payload[:taskId], call_id: payload[:callId], tool: tool,
        arguments: arguments, digest: payload[:digest]).deep_symbolize_keys
    end
end
