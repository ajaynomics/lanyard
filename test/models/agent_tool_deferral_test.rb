require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/mcp_test_helper"
require_relative "../test_helpers/passbolt_test_helper"

# #116: an agent's tools may outgrow Agent::TOOL_LIMIT, and the sidecar
# refuses a definition past it, and with it every message. A small core is
# declared in every message (Tool::Catalog::CORE); everything else, rare
# built-ins and connectors alike, is found with find_tools and called with
# use_tool, asking exactly as it would if called directly.
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
    # The sidecar's own check (agent/runtime.mjs validDefinition).
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").to_return do |request|
      definition = JSON.parse(request.body)["definition"]
      sent << definition
      definition["tools"].size > Agent::TOOL_LIMIT ? { status: 422, body: { error: "tool_limit" }.to_json } : { status: 202, body: { id: sent.size }.to_json }
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
    assert_includes @conversation.tool("use_tool").schema.dig("properties", "name", "enum"), "mcp__crm__tool_#{Agent::TOOL_LIMIT - 1}",
      "the pinned connector's last tools are looked up first"
    # Built-ins come first and spill last, so a core one (telegram_send among
    # them) is never looked up: use_tool can't reach it, and the ledger's
    # readers find its arguments at the top (Tool::TelegramSend.sent_to).
    core = @agent.own_tools.map(&:tool_name) & Tool::Catalog::CORE
    assert_includes core, "telegram_send"
    assert_equal core.sort, (core & sent.last["tools"].pluck("name")).sort, "every core built-in stays declared past the limit"
    assert_empty core & @conversation.tool("use_tool").schema.dig("properties", "name", "enum")
  ensure
    remove_sidecar_settings
    remove_fake_passbolt
  end

  test "the core list is declared in every message, and the rarer built-ins are looked up" do
    names = @conversation.tools.map(&:tool_name)

    assert_empty Tool::Catalog::CORE & %w[ change_yourself add_routine list_routines remove_routine make_agent join_concourse pay_by_card ]
    assert_includes names, "current_time"
    assert_includes names, "write_document"
    assert_includes names, "find_tools"
    assert_includes names, "use_tool"
    assert_empty names & %w[ change_yourself add_routine list_routines remove_routine ], "rare: looked up"
    assert_empty names - Tool::Catalog::CORE, "nothing else declared"
    assert_empty Tool::Catalog::CALENDAR.map(&:tool_name) - Tool::Catalog::CORE, "the agent's own calendar and tasks, used every day"
    looked_up = @conversation.tool("use_tool").schema.dig("properties", "name", "enum")
    assert_empty %w[ change_yourself add_routine list_routines remove_routine ] - looked_up
    assert_match "add_routine", @conversation.tool("find_tools").description, "find_tools names them, so the agent knows they are there"
    assert_includes @conversation.definition[:lookup].pluck(:name), "add_routine", "a codemode script's searchTools() finds them too"
  end

  test "a looked-up built-in is found and called through use_tool, and asks exactly as it does called directly" do
    found = receive("find_tools", "query" => "wake me with a routine on a schedule")[:result][:tools].pluck(:name)
    assert_includes found, "add_routine"

    routine = { "schedule" => "every weekday at 8am", "prompt" => "Brief me on the day." }
    with_setting(:app, :approve_everything, true) do
      assert_equal "waiting", receive("add_routine", routine)[:status], "called by its own name, as from a script"
      assert_equal "waiting", receive("use_tool", "name" => "add_routine", "arguments" => routine)[:status],
        "asks even where the install approves everything"
    end
    direct, used = @conversation.invocations.where(state: :awaiting_person).order(:id).to_a
    assert_equal [ :approval, :approval ], [ direct.asks, used.asks ]
    assert_equal direct.always_choices, used.always_choices
    assert_match(/routine/i, used.card_title)

    used.approve!(by: @alice)
    receive("use_tool", "name" => "add_routine", "arguments" => routine)
    perform_enqueued_jobs only: InvocationCallJob
    assert_equal "succeeded", used.reload.state, used.error
    assert_equal [ "Brief me on the day." ], @agent.routines.pluck(:prompt)
  end

  # A change to the workspace's shared instructions is the owner's alone, every
  # time (Tool::ChangeYourself): through use_tool it must read its own arguments.
  test "a looked-up tool that only one person may allow keeps that through use_tool" do
    change = { "instructions" => "Every agent signs off with its name.", "scope" => "workspace" }

    receive("change_yourself", change)
    receive("use_tool", "name" => "change_yourself", "arguments" => change)
    direct, used = @conversation.invocations.where(state: :awaiting_person).order(:id).to_a

    assert_equal direct.approver, used.approver
    assert_equal @agent.workspace.owner, used.approver
    assert_equal direct.approval_title, used.approval_title
    assert_equal [], used.always_choices
    with_setting(:app, :approve_everything, true) { assert_not @agent.allows?(used.send(:tool)), "every time" }
  end

  private
    def receive(tool, arguments)
      call_id = "toolu_#{Digest::SHA256.hexdigest([ tool, arguments ].to_json).first(12)}"
      payload = invocation_payload(@conversation, tool: tool, arguments: arguments, call_id: call_id)
      Invocation.receive(@conversation, task_id: payload[:taskId], call_id: payload[:callId], tool: tool,
        arguments: arguments, digest: payload[:digest]).deep_symbolize_keys
    end
end
