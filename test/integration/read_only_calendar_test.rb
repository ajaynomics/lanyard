require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/caldav_test_helper"
require_relative "../test_helpers/passbolt_test_helper"

# A colleague's calendars and task lists the agent took over, read only
# (docs/calendar.md, "Read-only calendar servers"): they sit beside its own as
# more lists; saving to or deleting from one is refused, by the tool and by
# the client, before anything is sent. The install's CalDAV server and the
# colleague's (WebMock) and the fake `passbolt` are the only stand-ins.
class ReadOnlyCalendarTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include ActiveJob::TestHelper
  include CaldavTestHelper
  include PassboltTestHelper

  SERVER = "https://dav.old.example.com"
  HOME = "/calendars/old/"
  LIST = "work@dav.old.example.com"

  setup do
    install_sidecar_settings
    install_caldav(username: "agent-1", password: "app-password")
    install_fake_passbolt(name: "Old calendar", uri: SERVER)
    @agent = create_user(name: "Alice").agents.sole
    @agent.update!(time_zone: "UTC", caldav_username: "agent-1", caldav_password: "app-password")
    @agent.calendar_servers.create!(read_only: true, url: SERVER + HOME, vault_entry: "Old calendar")
    @conversation = create_conversation(@agent)
    old_server
  end
  teardown do
    remove_fake_passbolt
    remove_caldav
    remove_sidecar_settings
  end

  test "its lists sit beside the agent's own, marked read only, and are read" do
    assert_nil @agent.calendar_server, "the writable one is still none"
    lists = call_tool("calendar_lists", {}, "c1")["result"]["lists"]
    assert_equal %w[ calendar tasks ] + [ LIST, "todo@dav.old.example.com" ], lists.pluck("list")
    assert_equal({ "list" => LIST, "name" => "Old work (read only)", "kinds" => [ "events" ], "own" => false }, lists[2])

    @old["standup"] = [ %("e1"), event_ics("standup", "Standup") ]
    found = call_tool("calendar_find", { "kind" => "events", "list" => LIST, "from" => "2026-11-19", "to" => "2026-11-21" }, "c2")["result"]["events"]
    assert_equal [ [ LIST, "standup", "Standup" ] ], found.map { it.values_at("list", "id", "title") }
  end

  test "saving or deleting on a read-only list is refused, by the tools and by the client, and nothing is written" do
    @old["standup"] = [ %("e1"), event_ics("standup", "Standup") ]
    refused = "#{LIST} is read only: nothing is saved or deleted there."
    { "calendar_save_event" => { "list" => LIST, "title" => "Lunch", "start" => "2026-11-20T12:00" },
      "calendar_save_task" => { "list" => "todo@dav.old.example.com", "title" => "Call back" },
      "calendar_delete" => { "list" => LIST, "id" => "standup" } }.each_with_index do |(tool, arguments), index|
      result = call_tool(tool, arguments, "w#{index}")
      assert result["isError"], tool
      assert_equal refused.sub(LIST, arguments["list"]), result["result"]["error"], tool
    end

    caldav = @agent.reload.caldav
    assert_raises(DurableAssistants::Caldav::Error, match: refused) { caldav.put(LIST, "x", Icalendar::Calendar.new) }
    assert_raises(DurableAssistants::Caldav::Error, match: refused) { caldav.delete(LIST, "standup", %("e1")) }
    assert_equal [ :propfind, :report, :get ].to_set.superset?(@old_requests.map(&:first).to_set), true, @old_requests.inspect
    assert_equal [ "standup" ], @old.keys
  end

  test "the agent's own lists are written as before" do
    saved = call_tool("calendar_save_event", { "list" => "calendar", "title" => "Lunch", "start" => "2026-11-20T12:00" }, "c1")["result"]["saved"]
    assert_equal "Lunch", caldav_item("calendar", saved["id"]).events.sole.summary.to_s
  end

  private
    def call_tool(tool, arguments, call_id)
      post_call = -> { post "/agent/invocations", params: invocation_payload(@conversation, tool:, arguments:, call_id:), headers: rails_bearer, as: :json }
      post_call.call
      perform_enqueued_jobs(only: InvocationCallJob)
      post_call.call
      response.parsed_body
    end

    def event_ics(id, title)
      Icalendar::Calendar.new.tap { |calendar| calendar.event { it.uid = id; it.summary = title; it.dtstart = Icalendar::Values::DateTime.new("20261120T090000Z"); it.dtend = Icalendar::Values::DateTime.new("20261120T093000Z") } }.to_ical
    end

    def old_server
      @old, @old_requests = {}, []
      stub_request(:any, /\A#{Regexp.escape(SERVER)}/).to_return do |request|
        path = request.uri.path
        @old_requests << [ request.method, path ]
        next { status: 401 } unless request.headers["Authorization"] == "Basic #{Base64.strict_encode64("maya:#{PassboltTestHelper::PASSWORD}")}"
        id = path.delete_prefix(HOME).split("/", 2).last.to_s.delete_suffix(".ics")
        case request.method
        when :propfind then multistatus([ collection("#{HOME}work/", "Old work", "VEVENT"), collection("#{HOME}todo/", "Old to do", "VTODO") ])
        when :report then multistatus(@old.map { |key, (etag, ics)| item("#{HOME}work/#{key}.ics", etag, ics) })
        when :get then @old[id] ? { status: 200, body: @old[id].last, headers: { "ETag" => @old[id].first } } : { status: 404 }
        else (@old["written"] = [ "", request.body ]) && { status: 201 }
        end
      end
    end
end
