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

  # pi's deferred exposure (docs/mcp.md, "Control tool exposure"): what
  # tool_search finds is a real tool from the next model call on.
  test "a tool find_tools found is declared as itself from the next turn, and called by name without searching again" do
    install_sidecar_settings
    sent = []
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions")
      .with { sent << JSON.parse(it.body)["definition"] }.to_return(status: 202, body: { id: 1 }.to_json)
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/12}).to_return(body: { entries: [], cursor: 0, more: false, status: "running", pendingInputs: [] }.to_json)
    crm = create_mcp_server(@agent, name: "crm", tools: [ mcp_tool("find_contact", description: "Look up a contact in the CRM.",
      annotations: { readOnlyHint: true }, properties: { name: { type: "string" } }, required: %w[ name ]) ])
    crm.update!(loaded: false)
    names = -> { sent.last["tools"].pluck("name") }

    @conversation.submit("Who is Ada?", request_id: "m-1")
    assert_not_includes names.(), "mcp__crm__find_contact"
    assert_equal "mcp__crm__find_contact", receive("find_tools", "query" => "crm contact")[:result][:tools].first[:name]

    @conversation.reload.submit("And Grace?", request_id: "m-2")
    assert_includes names.(), "mcp__crm__find_contact"
    assert_equal({ name: { type: "string" } }.deep_stringify_keys, sent.last["tools"].find { it["name"] == "mcp__crm__find_contact" }["parameters"]["properties"])
    stub_mcp_server(calls: { "find_contact" => ->(arguments) { { content: [ { type: "text", text: "#{arguments['name']} works at Acme" } ] } } })
    receive("mcp__crm__find_contact", "name" => "Grace")
    perform_enqueued_jobs only: InvocationCallJob
    assert_equal({ text: "Grace works at Acme" }, receive("mcp__crm__find_contact", "name" => "Grace")[:result])
    assert_equal %w[ find_tools mcp__crm__find_contact ], @conversation.invocations.order(:id).pluck(:tool_name).uniq, "no second search, no use_tool"

    digest = sent.last["digest"]
    @conversation.reload.submit("Thanks", request_id: "m-3")
    assert_equal digest, sent.last["digest"], "using an activated tool changes nothing the sidecar caches"
  ensure
    remove_sidecar_settings
  end

  test "activated tools fill the room left under the limit, the least recently used dropped first, and a branch keeps them" do
    @mail.update!(tools: Array.new(Agent::TOOL_LIMIT) { mcp_tool("tool_#{it}") }.map(&:deep_stringify_keys))
    room = Agent::TOOL_LIMIT - @conversation.tools.size
    names = Array.new(room + 2) { "mcp__gmail__tool_#{it}" }
    names.each { @conversation.activate([ it ]) }
    @conversation.activate([ names.first ]) # used again: now the most recent

    declared = @conversation.reload.tools.map(&:tool_name)
    assert_equal Agent::TOOL_LIMIT, declared.size
    assert_includes declared, names.first
    assert_not_includes declared, names.second, "the least recently used"
    assert_not_includes declared, names.third
    assert_includes declared, "use_tool", "still reaches the rest"
    assert_equal declared.grep(/gmail/).sort, declared.grep(/gmail/), "in name order, so recency never changes the definition"

    install_sidecar_settings
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/forks").to_return(status: 201, body: { id: 41 }.to_json)
    assert_equal @conversation.activated_tools, @conversation.branch(request_id: "b-1", after: 5).activated_tools, "a branch keeps them, as pi's transcript does"
  ensure
    remove_sidecar_settings
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
