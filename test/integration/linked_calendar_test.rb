require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/caldav_test_helper"
require_relative "../test_helpers/passbolt_test_helper"

# One calendar from another CalDAV account (docs/calendar.md), whose app
# password opens the whole account. The calendar tools see it as one more
# list; DurableAssistants::Caldav::Scoped reaches its collection and the items
# in it and nothing else, and the password goes from the vault into each
# request and nowhere else. The fake `passbolt` command and the CalDAV servers
# are the only stand-ins; the tools, the ledger and the client run for real.
class LinkedCalendarTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include ActiveJob::TestHelper
  include CaldavTestHelper
  include PassboltTestHelper

  KEY = PassboltTestHelper::PASSWORD
  SERVER = "https://caldav.icloud.example"
  COLLECTION = "/123456/calendars/family/"
  SECOND = "/123456/calendars/class/"

  setup do
    install_sidecar_settings
    install_fake_passbolt(name: "Family calendar", uri: SERVER)
    @alice = create_user(name: "Alice")
    @agent = @alice.agents.sole
    @agent.update!(time_zone: "Eastern Time (US & Canada)", linked_calendar_server: SERVER, linked_calendar: COLLECTION,
      linked_calendar_entry: "Family calendar")
    @conversation = create_conversation(@agent)
    linked_server
  end
  teardown do
    remove_fake_passbolt
    remove_sidecar_settings
  end

  test "nothing is read from the vault until a request is made" do
    assert @conversation.tool("calendar_find"), "the linked calendar alone gives the calendar tools"
    @agent.caldav
    assert_not_includes passbolt_calls, "get resource"
  end

  test "the tools see it as one more list, and read and write in it" do
    install_caldav(username: "agent-1", password: "app-password")
    @agent.update!(caldav_username: "agent-1", caldav_password: "app-password")

    lists = call_tool("calendar_lists", {}, "c1")["result"]["lists"]
    assert_equal %w[ calendar tasks family ], lists.pluck("list")
    assert_equal({ "list" => "family", "name" => "Family", "kinds" => [ "events" ], "own" => false }, lists.last)

    saved = call_tool("calendar_save_event", { "list" => "family", "title" => "Recital", "start" => "2026-11-20T18:00" }, "c2")["result"]["saved"]
    assert_equal "Recital", Icalendar::Calendar.parse(@linked.fetch(saved["id"]).last).first.events.sole.summary.to_s

    found = call_tool("calendar_find", { "kind" => "events", "from" => "2026-11-19", "to" => "2026-11-21" }, "c3")["result"]["events"]
    assert_equal [ [ "family", saved["id"], "Recital" ] ], found.map { it.values_at("list", "id", "title") }

    call_tool("calendar_delete", { "list" => "family", "id" => saved["id"] }, "c4")
    assert_empty @linked
    assert @linked_requests.all? { |_, path| path == COLLECTION || path.match?(%r{\A#{COLLECTION}[\w-]+\.ics\z}) }, @linked_requests.inspect
  ensure
    remove_caldav
  end

  test "two calendars of the same account, each read and written beside its own lists" do
    install_caldav(username: "agent-1", password: "app-password")
    @agent.update!(caldav_username: "agent-1", caldav_password: "app-password", linked_calendar: "#{COLLECTION}\n#{SECOND}")

    assert_equal %w[ calendar tasks family class ], call_tool("calendar_lists", {}, "c1")["result"]["lists"].pluck("list")
    saved = %w[ family class ].each_with_index.map do |list, index|
      call_tool("calendar_save_event", { "list" => list, "title" => "In #{list}", "start" => "2026-11-20T1#{index}:00" }, "s#{index}")["result"]["saved"]
    end
    assert_equal [ [ saved.first["id"] ], [ saved.last["id"] ] ], [ @linked.keys, @second.keys ]

    found = call_tool("calendar_find", { "kind" => "events", "from" => "2026-11-19", "to" => "2026-11-21" }, "c2")["result"]["events"]
    assert_equal [ [ "family", "In family" ], [ "class", "In class" ] ], found.map { it.values_at("list", "title") }

    call_tool("calendar_delete", { "list" => "class", "id" => saved.last["id"] }, "c3")
    assert_empty @second
    assert_equal 1, @linked.size
  ensure
    remove_caldav
  end

  test "while one calendar cannot be reached, the others still answer, and the agent is told why" do
    install_caldav(username: "agent-1", password: "app-password")
    @agent.update!(caldav_username: "agent-1", caldav_password: "app-password", linked_calendar: "#{COLLECTION}\n#{SECOND}")
    @down = SECOND
    @linked["e1"] = [ %("etag-1"), Icalendar::Calendar.new.tap { it.event { |event| event.uid = "e1"; event.summary = "Recital"
      event.dtstart = Icalendar::Values::DateTime.new("20261120T230000Z") } }.to_ical ]

    listed = call_tool("calendar_lists", {}, "c1")
    assert_not listed["isError"], listed.inspect
    assert_equal %w[ calendar tasks family ], listed["result"]["lists"].pluck("list")
    assert_equal [ "The calendar server couldn't list the calendars (HTTP 503)." ], listed["result"]["unreachable"]

    found = call_tool("calendar_find", { "kind" => "events", "from" => "2026-11-19", "to" => "2026-11-21" }, "c2")["result"]
    assert_equal [ "Recital" ], found["events"].pluck("title")
    assert_equal [ "The calendar server couldn't list the calendars (HTTP 503)." ], found["unreachable"]
  ensure
    remove_caldav
  end

  test "the app password never reaches the result, the ledger or the log, even when the server echoes it" do
    @echo = true
    caldav = Icalendar::Calendar.new.tap { it.event { |event| event.uid = "e1"; event.summary = "Recital"; event.description = "Sign in with #{KEY}"
      event.dtstart = Icalendar::Values::DateTime.new("20261120T230000Z") } }
    @linked["e1"] = [ %("etag-1"), caldav.to_ical ]

    log = capture_log do
      results = [ call_tool("calendar_lists", {}, "c1"), call_tool("calendar_find", { "kind" => "events", "from" => "2026-11-19", "to" => "2026-11-21" }, "c2") ]
      assert_equal [ "Family [the saved password]", "Sign in with [the saved password]" ],
        [ results.first["result"]["lists"].sole["name"], results.last["result"]["events"].sole["notes"] ]
      assert_not_includes results.to_json, KEY
    end
    assert_includes passbolt_calls, "get resource", "the password was read from the vault"
    assert_not_includes @conversation.invocations.reload.map(&:attributes).to_json, KEY
    assert_match "InvocationCallJob", log, "the log was read"
    assert_not_includes log, KEY
    assert_not_includes Agent.connection.select_all("select * from agents where id = #{@agent.id}").to_a.to_json, KEY # tenancy-ok: the test's own agent
  end

  test "it refuses a different calendar on the same account" do
    scoped = @agent.linked_caldavs.sole
    [ -> { scoped.items("work", "events") }, -> { scoped.item("work", "x") },
      -> { scoped.put("work", "x", Icalendar::Calendar.new) }, -> { scoped.delete("work", "x", %("e")) } ].each do |call|
      assert_raises(DurableAssistants::Caldav::Error) { call.call }
    end
    assert call_tool("calendar_find", { "kind" => "events", "list" => "work" }, "c1")["isError"]
    assert_empty @linked_requests
    assert_not_includes passbolt_calls, "get resource", "a refused request reads nothing from the vault"
  end

  test "it refuses any path outside the calendar: up, the principal, the home, another collection, contacts, a query" do
    scoped = @agent.linked_caldavs.sole
    [ [ "family", "../../../principal" ], [ "family", "../work/event" ], [ "family", "sub/x" ], [ "family", "x?depth=infinity" ],
      [ "..", nil ], [ "../../123456/principal", nil ], [ "../../123456/carddavhome/card", nil ], [ "family/..", nil ] ].each do |list, id|
      assert_raises(DurableAssistants::Caldav::Error, [ list, id ].inspect) { id ? scoped.item(list, id) : scoped.items(list, "events") }
    end
    assert_empty @linked_requests
  end

  test "the password goes only to the host saved with it in the vault" do
    @agent.update!(linked_calendar_server: "https://calendar.elsewhere.example")
    elsewhere = stub_request(:any, /elsewhere\.example/)
    result = call_tool("calendar_lists", {}, "c1")
    assert result["isError"]
    assert_match "is saved for caldav.icloud.example", result["result"].to_s
    assert_not_requested elsewhere
  end

  private
    def call_tool(tool, arguments, call_id)
      post_call = -> { post "/agent/invocations", params: invocation_payload(@conversation, tool:, arguments:, call_id:), headers: rails_bearer, as: :json }
      post_call.call
      perform_enqueued_jobs(only: InvocationCallJob)
      post_call.call
      response.parsed_body
    end

    # The other account's server: its family and class calendars, and an
    # answer, as a real account would give, for anything else on it.
    def linked_server
      @linked, @second, @linked_requests = {}, {}, []
      stub_request(:any, /\A#{Regexp.escape(SERVER)}/).to_return do |request|
        path = request.uri.path
        @linked_requests << [ request.method, path ]
        next { status: 401 } unless request.headers["Authorization"] == "Basic #{Base64.strict_encode64("maya:#{KEY}")}"
        at, (items, name) = { COLLECTION => [ @linked, "Family" ], SECOND => [ @second, "Class" ] }.find { |prefix, _| path.start_with?(prefix) }
        next { status: 503 } if at && at == @down
        id = path.delete_prefix(at).delete_suffix(".ics") if at && path != at
        case [ request.method, path == at ]
        when [ :propfind, true ] then multistatus([ collection(at, @echo ? "#{name} #{KEY}" : name, "VEVENT") ])
        when [ :report, true ] then multistatus(items.map { |key, (etag, ics)| item("#{at}#{key}.ics", etag, ics) })
        else id ? linked_item(items, request, id) : multistatus([])
        end
      end
    end

    def linked_item(items, request, id)
      case request.method
      when :get then items[id] ? { status: 200, body: items[id].last, headers: { "ETag" => items[id].first } } : { status: 404 }
      when :put then (items[id] = [ %("#{SecureRandom.hex(4)}"), request.body ]) && { status: 201 }
      when :delete then items.delete(id) && { status: 204 }
      end
    end

    def capture_log
      output = StringIO.new
      previous = Rails.logger
      Rails.logger = ActiveSupport::BroadcastLogger.new(previous, ActiveSupport::Logger.new(output))
      ActiveJob::Base.logger = ActionController::Base.logger = Rails.logger
      yield
      output.string
    ensure
      Rails.logger = ActiveJob::Base.logger = ActionController::Base.logger = previous
    end
end
