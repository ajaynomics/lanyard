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
    @wiki = create_mcp_server(@agent, name: "wiki", tools: [ mcp_tool("read_page") ])
    make_core(@agent, @wiki)
    @mail = create_mcp_server(@agent, name: "gmail", tools: [
      mcp_tool("search_threads", description: "Search email threads.", annotations: { readOnlyHint: true }, properties: { q: { type: "string" } }, required: %w[ q ]),
      mcp_tool("send_message", description: "Send an email.", properties: { to: { type: "string" } }, required: %w[ to ]),
      mcp_tool("trash_thread", description: "Move a thread to the bin.") ])
  end

  test "a connector that isn't core leaves the definition; find_tools and use_tool stand in, naming it" do
    names = @conversation.tools.map(&:tool_name)

    assert_includes names, "mcp__wiki__read_page"
    assert_empty names.grep(/gmail/)
    assert_equal 2, (names & %w[ find_tools use_tool ]).size
    assert_match "Connectors: gmail.", @conversation.tool("find_tools").description
    assert_no_match "Connectors", create_conversation(create_user(name: "Bob").agents.sole).tool("find_tools").description, "none without one"
  end

  # The sidecar refuses a definition whose lookup repeats a name or names a
  # declared tool, and so every message the agent is sent.
  test "two tools that read the same once sanitised are looked up once, and none shadows a declared one" do
    clash = create_mcp_server(@agent, name: "pages", tools: [ mcp_tool("get-page"), mcp_tool("get_page") ])
    lookup = @conversation.reload.definition[:lookup].pluck(:name)
    assert_equal lookup.uniq, lookup
    assert_equal 1, lookup.count("mcp__pages__get_page")
    assert_empty lookup & @conversation.definition[:tools].pluck(:name)
    assert clash.persisted?
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

  test "a looked-up connector doesn't count toward the limit, and one too big can't be made core" do
    stub_mcp_server(tools: Array.new(Agent::TOOL_LIMIT) { mcp_tool("tool_#{it}") })
    big = @alice.mcp_servers.create!(name: "crm", url: MCP_URL)

    big.refresh

    assert_nil big.reload.refresh_error
    assert_equal Agent::TOOL_LIMIT, big.tools.size
    assert_not @agent.core?(big)
    assert @conversation.tools.size <= Agent::TOOL_LIMIT
    assert_not @agent.core_connectors.create(mcp_server: big).persisted?
  end

  # pi's deferred exposure (docs/mcp.md, "Control tool exposure"), cut to what
  # the agent calls: a find for reading leaves the writing tools undeclared.
  test "where the agent keeps found tools, one it calls is its own from the next message, called by name; use_tool no longer offers it" do
    @agent.update!(promotes_found_tools: true)
    install_sidecar_settings
    sent = []
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions")
      .with { sent << JSON.parse(it.body)["definition"] }.to_return(status: 202, body: { id: 1 }.to_json)
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/12}).to_return(body: { entries: [], cursor: 0, more: false, status: "running", pendingInputs: [] }.to_json)
    crm = create_mcp_server(@agent, name: "crm", tools: [
      mcp_tool("find_many_companies", description: "Find companies in the CRM.", annotations: { readOnlyHint: true },
        properties: { name: { type: "string" } }, required: %w[ name ]),
      mcp_tool("update_many_companies", description: "Update companies in the CRM.") ])
    stub_mcp_server(calls: { "find_many_companies" => ->(arguments) { { content: [ { type: "text", text: "#{arguments['name']}: Acme" } ] } } })
    names = -> { sent.last["tools"].pluck("name") }
    offered = -> { sent.last["tools"].find { it["name"] == "use_tool" }.dig("parameters", "properties", "name", "enum") }

    @conversation.submit("Which companies are called Acme?", request_id: "m-1")
    found = receive("find_tools", "query" => "crm companies")[:result]
    assert_equal %w[ mcp__crm__find_many_companies mcp__crm__update_many_companies ], found[:tools].pluck(:name).sort
    assert_match "from the person's next message", found[:how]
    receive("use_tool", "name" => "mcp__crm__find_many_companies", "arguments" => { "name" => "Acme" })
    perform_enqueued_jobs only: InvocationCallJob
    assert_equal({ text: "Acme: Acme" }, receive("use_tool", "name" => "mcp__crm__find_many_companies", "arguments" => { "name" => "Acme" })[:result],
      "a call made before it was declared still runs")
    assert_equal %w[ mcp__crm__find_many_companies ], @conversation.reload.activated_tools, "what it called, not every match"

    @conversation.submit("And Initech?", request_id: "m-2")
    assert_includes names.(), "mcp__crm__find_many_companies"
    assert_not_includes names.(), "mcp__crm__update_many_companies"
    assert_equal %w[ mcp__crm__find_many_companies mcp__crm__update_many_companies ], offered.().grep(/crm/),
      "use_tool's declaration stays as it was, so the prompt cache holds"
    assert_equal %w[ mcp__crm__find_many_companies ], receive("find_tools", "query" => "find companies")[:result][:already_yours]
    receive("mcp__crm__find_many_companies", "name" => "Initech")
    perform_enqueued_jobs only: InvocationCallJob
    assert_equal({ text: "Initech: Acme" }, receive("mcp__crm__find_many_companies", "name" => "Initech")[:result])

    digest = sent.last["digest"]
    @conversation.reload.submit("Thanks", request_id: "m-3")
    assert_equal digest, sent.last["digest"], "calling a declared tool changes nothing the sidecar caches"
  ensure
    remove_sidecar_settings
  end

  test "activated tools fill the room left under the limit, the least recently used dropped first" do
    @agent.update!(promotes_found_tools: true)
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
  end

  test "a tool turned off for every agent on its connector, or for this agent only, is neither loaded nor found" do
    @mail.update!(disabled_tools: %w[ trash_thread ])
    @agent.switch_tool("mcp__gmail__send_message", false)
    @agent.switch_tool("mcp__wiki__read_page", false)
    other = create_conversation(@alice.personal_workspace.agents.create!(user: @alice, name: "Robin", instructions: "Help.", model: @agent.model), durable_id: "13")
    make_core(other.agent, @wiki)

    names = @conversation.reload.tools.map(&:tool_name)
    assert_not_includes names, "mcp__wiki__read_page", "core"
    assert_equal %w[ mcp__gmail__search_threads ], @conversation.tool("find_tools").tools.map(&:tool_name).grep(/\Amcp__/), "searched"
    assert_no_match(/trash_thread/, receive("find_tools", "query" => "zebra")[:result][:none_matched])
    assert receive("use_tool", "name" => "mcp__gmail__send_message", "arguments" => { "to" => "x@example.com" })[:isError]

    assert_includes other.tools.map(&:tool_name), "mcp__wiki__read_page", "another agent keeps what this one turned off"
    assert_equal %w[ mcp__gmail__search_threads mcp__gmail__send_message ], other.tool("find_tools").tools.map(&:tool_name).grep(/\Amcp__/).sort,
      "but not what is off for every agent"

    @agent.switch_tool("mcp__gmail__search_threads", false)
    assert_empty @conversation.reload.tool("find_tools").connector_names, "nothing left to find on a connector"
    @agent.switch_tool("mcp__wiki__read_page", true)
    assert_includes @conversation.reload.tools.map(&:tool_name), "mcp__wiki__read_page"
  end

  test "the settings' meter counts what the thread declares: find_tools and use_tool, not a looked-up connector's tools nor one it called" do
    @agent.update!(promotes_found_tools: true)
    loaded = @conversation.tools.size
    assert_equal loaded, @agent.tool_count
    assert_includes @conversation.tools.map(&:tool_name), "find_tools"

    @conversation.activate(%w[ mcp__gmail__search_threads ])
    assert_equal loaded + 1, @conversation.reload.tools.size
    assert_equal loaded, @agent.reload.tool_count, "a tool it looked up only fills spare room"

    make_core(@agent, @mail)
    assert_equal loaded + 3, @agent.reload.tool_count, "find_tools and use_tool stay for its own rarer tools"
    assert @agent.switch_tool("current_time", false)
    assert @agent.switch_tool("web_search", false)
    assert_equal loaded + 3 - 1, @agent.reload.tool_count, "an ability is not a tool"
    assert_not_includes @agent.capabilities, "web_search"
    assert_not_includes @agent.tool_names, "current_time"
  end

  test "a person's connector is looked up until made core: the declared count drops, and stays the same however many are added" do
    looked_up = @conversation.tools.size
    make_core(@agent, @mail)
    assert_equal looked_up + 3, @conversation.reload.tools.size, "core, its three tools join the rest"
    @agent.core_connectors.where(mcp_server: @mail).delete_all

    3.times { |n| create_mcp_server(@agent, name: "extra_#{n}", tools: Array.new(20) { mcp_tool("tool_#{it}") }) }
    assert_equal looked_up, @conversation.reload.tools.size, "sixty more tools, none declared"
    assert_equal 3 + 60, @conversation.lookup_tools.map(&:tool_name).grep(/\Amcp__/).size
    robin = create_conversation(@alice.personal_workspace.agents.create!(user: @alice, name: "Robin", instructions: "Help.", model: @agent.model), durable_id: "13")
    assert_empty robin.tools.map(&:tool_name).grep(/\Amcp__/), "a new agent too: nothing is core for it until made so"
    assert_equal 1 + 3 + 60, robin.lookup_tools.map(&:tool_name).grep(/\Amcp__/).size, "wiki too, core only for the other agent"
  end

  test "with code mode, the definition carries the looked-up tools as lookup, apart from the declared ones; without, as before" do
    @agent.switch_tool("mcp__gmail__trash_thread", false)
    definition = @conversation.reload.definition
    lookup = definition[:lookup].index_by { it[:name] }

    assert_equal %w[ mcp__gmail__search_threads mcp__gmail__send_message ], lookup.keys.grep(/\Amcp__/).sort, "not a tool switched off"
    assert_equal({ "type" => "object", "properties" => { "q" => { "type" => "string" } }, "required" => %w[ q ] }, lookup["mcp__gmail__search_threads"][:parameters])
    assert_empty lookup.keys & definition[:tools].pluck(:name)
    assert_match "or from a codemode script, where searchTools() finds them too, as tools.<name>(...)", @conversation.tool("find_tools").description
    assert_match "from a codemode script, call it as tools.<name>(...)", receive("find_tools", "query" => "search email")[:result][:how]

    @agent.switch_tool("codemode", false)
    definition = @conversation.reload.definition
    assert_not definition.key?(:lookup)
    assert_equal Agent::Canonical.digest(definition.except(:digest)), definition[:digest]
    assert_no_match "codemode", @conversation.tool("find_tools").description
    assert_no_match "codemode", receive("find_tools", "query" => "send email")[:result][:how]
  end

  # A code mode script calls a looked-up tool by its own name (agent/extensions.mjs): the same Tool::Mcp
  # use_tool reaches, so the same inputs, approvals and switches, and the same ledger.
  test "a looked-up tool called by its own name, as from a script, asks and refuses exactly as through use_tool" do
    stub_mcp_server(calls: { "search_threads" => ->(arguments) { { content: [ { type: "text", text: "3 threads for #{arguments['q']}" } ] } } })
    assert_not @conversation.declares?("mcp__gmail__search_threads")

    receive("mcp__gmail__search_threads", "q" => "rent")
    perform_enqueued_jobs only: InvocationCallJob
    assert_equal({ text: "3 threads for rent" }, receive("mcp__gmail__search_threads", "q" => "rent")[:result], "read-only: at once")
    assert receive("mcp__gmail__search_threads", {})[:isError], "its own schema"

    direct = receive("mcp__gmail__send_message", "to" => "bob@example.test")
    used = receive("use_tool", "name" => "mcp__gmail__send_message", "arguments" => { "to" => "bob@example.test" })
    assert_equal %w[ waiting waiting ], [ direct[:status], used[:status] ]
    cards = @conversation.invocations.where(state: :awaiting_person).order(:id)
    assert_equal [ :approval, :approval ], cards.map(&:asks)
    assert_equal [ %w[ agent ], %w[ agent ] ], cards.map(&:always_choices)
    assert_not_requested :post, MCP_URL, body: /send_message/

    with_setting(:app, :approve_everything, true) do
      @mail.update!(asks_every_write: true)
      assert_equal "waiting", receive("mcp__gmail__send_message", "to" => "sam@example.test")[:status], "asks every time either way"
      assert_equal "waiting", receive("use_tool", "name" => "mcp__gmail__send_message", "arguments" => { "to" => "sam@example.test" })[:status]
    end

    @agent.switch_tool("mcp__gmail__send_message", false)
    @mail.update!(disabled_tools: %w[ trash_thread ])
    [ [ "mcp__gmail__send_message", { "to" => "x@example.test" } ], [ "mcp__gmail__trash_thread", {} ] ].each do |name, arguments|
      assert_match "not one of this agent's tools", receive(name, arguments)[:result][:error], "switched off: unreachable by name"
      assert receive("use_tool", "name" => name, "arguments" => arguments)[:isError], "and through use_tool"
    end
    assert_empty @conversation.reload.activated_tools, "nothing is promoted without the setting"
  end

  # Mid-deploy the agent role may still run a sidecar from before lookup, which refuses the key.
  test "a sidecar that refuses lookup gets the same message again without it, and use_tool still reaches the tools" do
    install_sidecar_settings
    sent = []
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions")
      .with { sent << JSON.parse(it.body)["definition"] }
      .to_return({ status: 422, body: { error: "invalid_definition" }.to_json }, { status: 202, body: { id: 1 }.to_json })
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/12}).to_return(body: { entries: [], cursor: 0, more: false, status: "running", pendingInputs: [] }.to_json)

    @conversation.submit("Any mail about rent?", request_id: "m-1")

    assert_equal [ true, false ], sent.map { it.key?("lookup") }
    assert_equal Agent::Canonical.digest(sent.last.except("digest")), sent.last["digest"]
    assert_includes sent.last["tools"].pluck("name"), "use_tool"
    assert_equal sent.last["digest"], @conversation.reload.definition_digest
  ensure
    remove_sidecar_settings
  end

  test "without the setting nothing a found tool does is promoted; with it, as before" do
    stub_mcp_server(calls: { "search_threads" => ->(_) { { content: [ { type: "text", text: "none" } ] } } })
    call = { "name" => "mcp__gmail__search_threads", "arguments" => { "q" => "rent" } }
    assert_no_match "next message", @conversation.tool("use_tool").description
    assert_no_match "becomes one of your own", receive("find_tools", "query" => "search email")[:result][:how]

    receive("use_tool", call)
    assert_empty @conversation.reload.activated_tools
    @conversation.update!(activated_tools: %w[ mcp__gmail__search_threads ])
    assert_not_includes @conversation.reload.tools.map(&:tool_name), "mcp__gmail__search_threads", "an activation from before is not declared"

    @agent.update!(promotes_found_tools: true)
    @conversation.update!(activated_tools: [])
    assert_match "one of your own from the person's next message", @conversation.reload.tool("use_tool").description
    receive("use_tool", call.merge("arguments" => { "q" => "rates" }))
    assert_equal %w[ mcp__gmail__search_threads ], @conversation.reload.activated_tools
    assert_includes @conversation.tools.map(&:tool_name), "mcp__gmail__search_threads"
    assert_not_includes @conversation.lookup_tools.map(&:tool_name), "mcp__gmail__search_threads", "declared, so not lookup"
  end

  # A person's "Always" is kept under the looked-up tool's own name, so the
  # next call through use_tool is allowed and a different tool still asks.
  test "Always for a looked-up built-in through use_tool covers its next call there, and no other tool" do
    asked = ->(name, arguments) { receive("use_tool", "name" => name, "arguments" => arguments) && @conversation.invocations.order(:id).last.awaiting_person? }
    assert asked.("remove_routine", { "id" => 1 })
    @conversation.invocations.order(:id).last.approve!(by: @alice, always: "agent")
    assert_equal [ "remove_routine" ], @agent.permissions.pluck(:tool_name), "kept under its own name, not use_tool"

    assert_not asked.("remove_routine", { "id" => 2 }), "the next call through use_tool runs without asking"
    assert asked.("add_routine", { "schedule" => "every day at 9am", "prompt" => "Check the post." }), "another tool still asks"
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
