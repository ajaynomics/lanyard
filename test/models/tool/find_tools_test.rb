require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/mcp_test_helper"

class Tool::FindToolsTest < ActiveSupport::TestCase
  include AgentTestHelper
  include McpTestHelper
  include ActiveJob::TestHelper

  setup do
    @alice = create_user(name: "Alice")
    @agent = @alice.agents.sole
    @conversation = create_conversation(@agent)
    create_mcp_server(@agent, name: "wiki", tools: [ mcp_tool("read_page") ])
    @mail = create_mcp_server(@agent, name: "gmail", tools: [
      mcp_tool("search_threads", description: "Search email threads.", annotations: { readOnlyHint: true }, properties: { q: { type: "string" } }, required: %w[ q ]),
      mcp_tool("send_message", description: "Send an email.", properties: { to: { type: "string" } }, required: %w[ to ]),
      mcp_tool("trash_thread", description: "Move a thread to the bin.") ])
    @mail.update!(loaded: false)
  end

  test "a connector that isn't loaded leaves the definition; find_tools and use_tool stand in, naming it" do
    names = @conversation.tools.map(&:tool_name)

    assert_includes names, "mcp__wiki__read_page"
    assert_empty names.grep(/gmail/)
    assert_equal 2, (names & %w[ find_tools use_tool ]).size
    assert_match(/gmail \(search_threads, send_message, trash_thread\)/, @conversation.tool("find_tools").description)
    assert_not_includes create_conversation(create_user(name: "Bob").agents.sole).tools.map(&:tool_name), "find_tools", "none without one"
  end

  test "find_tools returns the best matches with their full inputs, and every name when nothing matches" do
    found = receive("find_tools", "query" => "search my email")[:result][:tools]

    assert_equal "mcp__gmail__search_threads", found.first[:name]
    assert_equal({ type: "object", properties: { q: { type: "string" } }, required: %w[ q ] }, found.first[:parameters])
    assert_match(/mcp__gmail__trash_thread/, receive("find_tools", "query" => "zebra")[:result][:none_matched])
  end

  test "use_tool checks the tool's own inputs, runs a read-only one at once and asks first for anything else" do
    stub_mcp_server(calls: { "search_threads" => ->(arguments) { { content: [ { type: "text", text: "3 threads for #{arguments['q']}" } ] } },
                             "send_message" => ->(arguments) { { content: [ { type: "text", text: "sent to #{arguments['to']}" } ] } } })

    assert receive("use_tool", "name" => "mcp__gmail__search_threads", "arguments" => {})[:isError], "its own schema"
    assert receive("use_tool", "name" => "mcp__gmail__nope", "arguments" => {})[:isError]

    receive("use_tool", "name" => "mcp__gmail__search_threads", "arguments" => { "q" => "rent" })
    perform_enqueued_jobs only: InvocationCallJob
    assert_equal({ text: "3 threads for rent" }, receive("use_tool", "name" => "mcp__gmail__search_threads", "arguments" => { "q" => "rent" })[:result])

    send = { "name" => "mcp__gmail__send_message", "arguments" => { "to" => "bob@example.test" } }
    assert_equal "waiting", receive("use_tool", send)[:status]
    invocation = @conversation.invocations.find_by(tool_name: "use_tool", state: :awaiting_person)
    assert_equal :approval, invocation.asks
    assert_not_requested :post, MCP_URL, body: /send_message/
    invocation.approve!(by: @alice)
    receive("use_tool", send)
    perform_enqueued_jobs only: InvocationCallJob
    assert_equal({ text: "sent to bob@example.test" }, receive("use_tool", send)[:result])
  end

  test "the approval shows the tool it calls" do
    receive("use_tool", "name" => "mcp__gmail__send_message", "arguments" => { "to" => "bob@example.test" })
    html = ApplicationController.render(partial: "invocations/invocation", locals: { invocation: @conversation.invocations.sole })

    assert_match "Allow send message (gmail)?", html
    assert_match "Send an email.", html
    assert_match %r{<dt>To</dt>\s*<dd>\s*<span class="ui-fields__text">bob@example.test}, html, "its inputs as fields, not JSON"
  end

  test "a connector that isn't loaded doesn't count toward the limit; a refresh that would pass it stops loading it" do
    stub_mcp_server(tools: Array.new(Agent::TOOL_LIMIT) { mcp_tool("tool_#{it}") })
    big = @alice.mcp_servers.create!(name: "crm", url: MCP_URL)

    big.refresh

    assert_nil big.reload.refresh_error
    assert_equal Agent::TOOL_LIMIT, big.tools.size
    assert_not big.loaded?
    assert @conversation.tools.size <= Agent::TOOL_LIMIT
    assert_not big.update(loaded: true)
  end

  private
    def receive(tool, arguments)
      # One call id for each distinct call, so a repeat is the sidecar's replay.
      call_id = "toolu_#{Digest::SHA256.hexdigest([ tool, arguments ].to_json).first(12)}"
      payload = invocation_payload(@conversation, tool: tool, arguments: arguments, call_id: call_id)
      Invocation.receive(@conversation, task_id: payload[:taskId], call_id: payload[:callId], tool: tool,
        arguments: arguments, digest: payload[:digest]).deep_symbolize_keys
    end
end
