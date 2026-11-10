require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

# Two or more Google connectors of one kind give an agent one set of that
# kind's tools, with an account argument (Tool::Mcp::Group). The connectors
# are unchanged: each keeps its own sign-in, switches and "Always" answers.
class Tool::McpGroupTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include AgentTestHelper

  GMAIL = "https://gmail.googleapis.com/gmail/v1/users/me".freeze

  setup do
    @agent = create_user.agents.sole
    @conversation = create_conversation(@agent)
  end

  test "two Gmail connectors are one set of tools, by account; a single connector keeps its names" do
    connector("gmail", "personal", "access-1")
    connector("gmail", "work", "access-2")
    connector("calendar", "diary", "access-3")
    names = tools.map(&:tool_name)

    assert_includes names, "mcp__gmail__search_threads"
    assert_empty names.grep(/\Amcp__(personal|work)__/), "the accounts' own names are gone"
    assert_includes names, "mcp__diary__list_events", "one Calendar connector is as it was"
    assert_equal 1, names.count("mcp__gmail__send_draft")

    account = tool("mcp__gmail__search_threads").schema.dig("properties", "account")
    assert_equal %w[ personal work ], account["enum"]
    assert_match "personal when left out", account["description"]
    assert_not_includes tool("mcp__gmail__search_threads").schema["required"].to_a, "account"
  end

  test "a call goes to the account it names, with that connector's token, and to the first by name when it names none" do
    connector("gmail", "work", "access-2")
    connector("gmail", "personal", "access-1")
    personal = stub_request(:get, "#{GMAIL}/threads").with(headers: { "Authorization" => "Bearer access-1" }, query: hash_including({})).to_return(json(threads: []))
    work = stub_request(:get, "#{GMAIL}/threads").with(headers: { "Authorization" => "Bearer access-2" }, query: hash_including({})).to_return(json(threads: []))

    call_tool("mcp__gmail__search_threads", "query" => "from:sam", "account" => "work")
    assert_requested work, times: 1
    assert_not_requested personal

    call_tool("mcp__gmail__search_threads", "query" => "from:sam")
    assert_requested personal, times: 1
  end

  test "account is the group's own: Google never gets it, even from a tool that passes its fields on" do
    connector("calendar", "home", "access-1")
    connector("calendar", "office", "access-2")
    made = stub_request(:post, "https://www.googleapis.com/calendar/v3/calendars/primary/events").with(headers: { "Authorization" => "Bearer access-2" }, query: hash_including({}))
      .to_return(json(id: "e1", summary: "Call", start: { date: "2026-11-20" }, end: { date: "2026-11-21" }))

    arguments = { "summary" => "Call", "start" => "2026-11-20", "end" => "2026-11-21", "account" => "office" }
    group = tool("mcp__calendar__create_event")
    given = []
    server = group.member(arguments).server
    server.define_singleton_method(:call_tool) { |name, values, **options| given << values; super(name, values, **options) }
    with_google_app { group.new(Invocation.new(conversation: @conversation, tool_name: group.tool_name, arguments: arguments)).call(**arguments.symbolize_keys) }

    assert_equal [ %i[ summary start end ] ], given.map(&:keys)
    assert_requested made.with { JSON.parse(it.body).exclude?("account") }
  end

  test "an account that can't use a tool is named in the error, before anything is asked" do
    connector("gmail", "personal", "access-1")
    connector("gmail", "work", "access-2").update!(disabled_tools: [ "send_message" ])

    assert_equal [ "work can't send_message: its sign-in doesn't allow it, or it is switched off there" ],
      tool("mcp__gmail__send_message").errors_for("to" => [ "sam@example.com" ], "body" => "Hi.", "account" => "work")
    assert_empty tool("mcp__gmail__send_message").errors_for("to" => [ "sam@example.com" ], "body" => "Hi.", "account" => "personal")
    assert_not_empty tool("mcp__gmail__send_message").errors_for("to" => [ "sam@example.com" ], "body" => "Hi.", "account" => "elsewhere")
  end

  test "the card names the account, and an Always for one account is not one for the other" do
    connector("gmail", "personal", "access-1")
    connector("gmail", "work", "access-2")
    arguments = { "to" => [ "sam@example.com" ], "subject" => "Lunch", "body" => "Hi." }

    asked = receive("mcp__gmail__create_draft", arguments.merge("account" => "work"), "c1")
    assert asked.awaiting_person?
    assert_equal "Allow create draft as work?", asked.tool_class.approval_title(asked.arguments)
    asked.approve!(by: @agent.user, always: "agent")

    assert_equal [ "mcp__work__create_draft" ], @agent.permissions.pluck(:tool_name), "granted as the connector's own tool"
    assert receive("mcp__gmail__create_draft", arguments.merge("account" => "personal"), "c2").awaiting_person?
    assert_not receive("mcp__gmail__create_draft", arguments.merge("account" => "work"), "c3").awaiting_person?
  end

  test "the set is loaded when any of its connectors is, and looked up when none is" do
    connector("gmail", "personal", "access-1").update!(loaded: false)
    work = connector("gmail", "work", "access-2")
    assert_includes tools.map(&:tool_name), "mcp__gmail__search_threads"

    work.update!(loaded: false)
    assert_not_includes tools.map(&:tool_name), "mcp__gmail__search_threads"
    assert_includes tool("use_tool").schema.dig("properties", "name", "enum"), "mcp__gmail__search_threads"
  end

  private
    def connector(kind, name, token)
      with_google_app do
        @agent.user.mcp_servers.create!(name: name, **McpServer.gallery_attributes(kind), refreshed_at: Time.current,
          oauth_tokens: { "access_token" => token, "refresh_token" => "refresh-#{name}", "expires_at" => 1.hour.from_now.to_i })
      end
    end

    def tools = @agent.reload.conversation.tools
    def tool(name) = @agent.reload.conversation.tool(name)

    def call_tool(name, arguments)
      with_google_app { tool(name).new(Invocation.new(conversation: @conversation, tool_name: name, arguments: arguments)).call(**arguments.symbolize_keys) }
    end

    def receive(name, arguments, call_id)
      payload = invocation_payload(@conversation, tool: name, arguments: arguments, call_id: call_id)
      with_google_app { Invocation.receive(@conversation, task_id: payload[:taskId], call_id: call_id, tool: name, arguments: arguments, digest: payload[:digest]) }
      @conversation.invocations.find_by!(call_id: call_id)
    end

    def with_google_app
      x = Rails.application.config.x
      saved, x.connectors = x.connectors, x.connectors.to_h.deep_merge(apps: { google: { client_id: "instance-id", client_secret: "instance-secret" } })
      yield
    ensure
      x.connectors = saved
    end

    def json(body) = { status: 200, headers: { "Content-Type" => "application/json" }, body: body.to_json }
end
