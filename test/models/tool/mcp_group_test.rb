require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

# Two or more Google connectors of one kind give an agent one set of that
# kind's tools, with an account argument (Tool::Mcp::Group). The connectors
# are unchanged: each keeps its own sign-in, switches and "Always" answers.
class Tool::McpGroupTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include AgentTestHelper

  GMAIL = "https://gmail.googleapis.com/gmail/v1/users/me".freeze
  CALENDAR = "https://www.googleapis.com/calendar/v3".freeze

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

  test "a Calendar ID does not switch accounts, and access belongs to the selected account" do
    connector("calendar", "office", "access-office")
    connector("calendar", "home", "access-home")
    shared_id = "shared@example.com"
    office_id = "office@example.com"
    home_auth = { "Authorization" => "Bearer access-home" }
    office_auth = { "Authorization" => "Bearer access-office" }

    stub_request(:get, "#{CALENDAR}/users/me/calendarList").with(headers: home_auth)
      .to_return(json(items: [ { id: shared_id, summary: "Team", accessRole: "reader" } ]))
    stub_request(:get, "#{CALENDAR}/users/me/calendarList").with(headers: office_auth)
      .to_return(json(items: [ { id: shared_id, summary: "Team", accessRole: "writer" },
        { id: office_id, summary: "Team", accessRole: "owner", primary: true } ]))

    home = call_tool("mcp__calendar__list_calendars", {})
    office = call_tool("mcp__calendar__list_calendars", "account" => "office")
    assert_equal [ [ shared_id, "reader" ] ], home.fetch("calendars").map { it.values_at("calendar_id", "access") }
    assert_equal [ [ shared_id, "writer" ], [ office_id, "owner" ] ], office.fetch("calendars").map { it.values_at("calendar_id", "access") }

    event_url = "#{CALENDAR}/calendars/office%40example.com/events/e1"
    unavailable = stub_request(:get, event_url).with(headers: home_auth)
      .to_return(json(error: { message: "Not Found" }).merge(status: 404))
    available = stub_request(:get, event_url).with(headers: office_auth)
      .to_return(json(id: "e1", summary: "Office appointment"))

    arguments = { "calendar_id" => office_id, "event_id" => "e1" }
    error = assert_raises(Tool::Refusal) { call_tool("mcp__calendar__get_event", arguments.merge("account" => "home")) }
    assert_match "Not Found", error.message
    assert_requested unavailable, times: 1
    assert_not_requested available

    assert_equal({ "event_id" => "e1", "summary" => "Office appointment" },
      call_tool("mcp__calendar__get_event", arguments.merge("account" => "office")))
    assert_requested available, times: 1
  end

  test "a looked-up Calendar tool names its accounts and calls either by name" do
    connector("calendar", "home_calendar", "home-access", core: false)
    studio = connector("calendar", "studio_calendar", "old-studio-access", core: false)
    studio.update!(oauth_tokens: studio.oauth_tokens.merge("expires_at" => 1.day.ago.to_i))

    name = "mcp__calendar__list_calendars"
    declaration = @conversation.reload.definition.fetch(:lookup).find { it[:name] == name }
    assert_equal %w[ home_calendar studio_calendar ], declaration.dig(:parameters, "properties", "account", "enum")
    assert_includes declaration[:description], "home_calendar, studio_calendar"
    assert_includes declaration[:description], "account"

    renewal = stub_request(:post, "https://oauth2.googleapis.com/token").with(body: hash_including("refresh_token" => "refresh-studio_calendar"))
      .to_return(json(access_token: "new-studio-access", expires_in: 3600))
    home = stub_request(:get, "#{CALENDAR}/users/me/calendarList").with(headers: { "Authorization" => "Bearer home-access" })
      .to_return(json(items: [ { id: "home@example.com", summary: "Home", accessRole: "owner" } ]))
    studio = stub_request(:get, "#{CALENDAR}/users/me/calendarList").with(headers: { "Authorization" => "Bearer new-studio-access" })
      .to_return(json(items: [ { id: "studio@example.com", summary: "Studio", accessRole: "reader" } ]))

    call = receive(name, { "account" => "studio_calendar" }, "studio-call")
    assert call.succeeded?, call.error
    assert_equal [ "studio@example.com" ], call.result.fetch("calendars").pluck("calendar_id")
    assert_requested renewal, times: 1
    assert_requested studio, times: 1
    assert_not_requested home

    call = receive(name, { "account" => "home_calendar" }, "home-call")
    assert call.succeeded?, call.error
    assert_equal [ "home@example.com" ], call.result.fetch("calendars").pluck("calendar_id")
    assert_requested home, times: 1
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

  test "the set is core when any of its connectors is, and looked up when none is" do
    connector("gmail", "personal", "access-1", core: false)
    work = connector("gmail", "work", "access-2")
    assert_includes tools.map(&:tool_name), "mcp__gmail__search_threads"

    @agent.core_connectors.where(mcp_server: work).delete_all
    assert_not_includes tools.map(&:tool_name), "mcp__gmail__search_threads"
    assert_includes @agent.reload.conversation.lookup_tools.map(&:tool_name), "mcp__gmail__search_threads"
  end

  private
    # Core for the agent unless `core: false`.
    def connector(kind, name, token, core: true)
      with_google_app do
        @agent.user.mcp_servers.create!(name: name, **McpServer.gallery_attributes(kind), refreshed_at: Time.current,
          oauth_tokens: { "access_token" => token, "refresh_token" => "refresh-#{name}", "expires_at" => 1.hour.from_now.to_i })
      end.tap { make_core(@agent, it) if core }
    end

    def tools = @agent.reload.conversation.tools
    def tool(name) = @agent.reload.conversation.tool(name)

    def call_tool(name, arguments)
      with_google_app { tool(name).new(Invocation.new(conversation: @conversation, tool_name: name, arguments: arguments)).call(**arguments.symbolize_keys) }
    end

    def receive(name, arguments, call_id)
      payload = invocation_payload(@conversation, tool: name, arguments: arguments, call_id: call_id)
      with_google_app do
        perform_enqueued_jobs(only: InvocationCallJob) do
          Invocation.receive(@conversation, task_id: payload[:taskId], call_id: call_id, tool: name, arguments: arguments, digest: payload[:digest])
        end
      end
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
