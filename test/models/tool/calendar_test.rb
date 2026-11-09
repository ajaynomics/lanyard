require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/caldav_test_helper"

class Tool::CalendarTest < ActiveSupport::TestCase
  include AgentTestHelper
  include CaldavTestHelper
  include ActiveJob::TestHelper

  setup do
    @items = install_caldav(username: "agent-1", password: "app-password")
    @maya = create_user(name: "Maya")
    @agent = @maya.agents.sole
    @agent.update!(time_zone: "Eastern Time (US & Canada)", caldav_username: " agent-1 ", caldav_password: "app-password")
    @conversation = create_conversation(@agent)
  end

  teardown { remove_caldav }

  test "an agent has the calendar tools only with an account of its own, where the install names the server" do
    assert_equal "agent-1", @agent.caldav_username
    assert_equal Tool::Catalog::CALENDAR.map(&:tool_name), tool_names & Tool::Catalog::CALENDAR.map(&:tool_name)
    with_setting(:caldav, :url, nil) { assert_not_includes tool_names, "calendar_find" }
    @agent.update!(caldav_password: nil)
    assert_not_includes tool_names, "calendar_find"
  end

  test "the app password is kept encrypted" do
    assert_not_includes Agent.connection.select_value("select caldav_password from agents where id = #{@agent.id}"), "app-password"
  end

  test "lists come by the name the other tools take" do
    assert_equal [ { list: "calendar", name: "Maya's calendar", kinds: [ "events" ] }, { list: "tasks", name: "Maya's tasks", kinds: [ "tasks" ] } ],
      run_call("c1", "calendar_lists", {})[:result][:lists]
  end

  test "an event is written in the agent's zone, found, changed only where named, and deleted" do
    saved = run_call("c1", "calendar_save_event", "list" => "calendar", "title" => "Dentist", "start" => "2026-11-12T15:00",
      "location" => "Main St", "alarm_minutes" => 0)[:result][:saved]
    assert_equal [ "Dentist", "2026-11-12T15:00:00-05:00", "2026-11-12T16:00:00-05:00" ], saved.values_at(:title, :start, :end)
    event = caldav_item("calendar", saved[:id]).events.sole
    assert_equal "America/New_York", event.dtstart.ical_params["tzid"].first
    assert_match(/^TRIGGER:PT0S\r?$/, @items["calendar"][saved[:id]].last, "an alarm at the time is a duration Radicale accepts")

    run_call("c2", "calendar_save_event", "list" => "calendar", "id" => saved[:id], "start" => "2026-11-12T16:30", "notes" => "Bring the card")
    event = caldav_item("calendar", saved[:id]).events.sole
    assert_equal [ "Dentist", "Main St", "Bring the card", 1 ], [ event.summary, event.location, event.description, event.sequence ].map(&:to_s).map { it.match?(/\A\d+\z/) ? it.to_i : it }
    assert_equal 1, event.alarms.size

    found = run_call("c3", "calendar_find", "kind" => "events", "from" => "2026-11-09", "to" => "2026-11-20", "query" => "dent")[:result][:events]
    assert_equal [ [ saved[:id], "2026-11-12T16:30:00-05:00", "2026-11-12T17:30:00-05:00" ] ], found.map { it.values_at(:id, :start, :end) }

    assert_equal({ deleted: saved[:id], list: "calendar" }, run_call("c4", "calendar_delete", "list" => "calendar", "id" => saved[:id])[:result])
    assert_empty @items["calendar"]
  end

  test "an all-day event is given and shown by its first and last day" do
    saved = run_call("c1", "calendar_save_event", "list" => "calendar", "title" => "Trip", "start" => "2026-11-20", "end" => "2026-11-22")[:result][:saved]
    assert_equal [ "2026-11-20", "2026-11-22", true ], saved.values_at(:start, :end, :all_day)
    assert_equal Date.new(2026, 11, 23), caldav_item("calendar", saved[:id]).events.sole.dtend.value
  end

  test "what a phone wrote stays as it was" do
    caldav_put "calendar", "phone-1", <<~ICS.gsub("\n", "\r\n")
      BEGIN:VCALENDAR
      VERSION:2.0
      PRODID:-//Apple Inc.//iOS 26//EN
      BEGIN:VEVENT
      UID:phone-1
      DTSTAMP:20261101T120000Z
      DTSTART:20261116T140000Z
      DTEND:20261116T143000Z
      SUMMARY:Standup
      RRULE:FREQ=WEEKLY;BYDAY=MO
      X-APPLE-TRAVEL-ADVISORY-BEHAVIOR:AUTOMATIC
      BEGIN:VALARM
      ACTION:DISPLAY
      TRIGGER:-PT10M
      END:VALARM
      END:VEVENT
      END:VCALENDAR
    ICS
    run_call("c1", "calendar_save_event", "list" => "calendar", "id" => "phone-1", "title" => "Team standup")
    stored = @items["calendar"]["phone-1"].last
    assert_match "SUMMARY:Team standup", stored
    assert_match "RRULE:FREQ=WEEKLY;BYDAY=MO", stored
    assert_match "X-APPLE-TRAVEL-ADVISORY-BEHAVIOR:AUTOMATIC", stored
    assert_match "TRIGGER:-PT10M", stored
  end

  test "changing something changed meanwhile is refused, and the agent told to read it again" do
    saved = run_call("c1", "calendar_save_event", "list" => "calendar", "title" => "Lunch", "start" => "2026-11-12T12:00")[:result][:saved]
    stub_request(:get, /#{saved[:id]}/).to_return(status: 200, body: @items["calendar"][saved[:id]].last, headers: { "ETag" => %("old") })
    outcome = run_call("c2", "calendar_save_event", "list" => "calendar", "id" => saved[:id], "title" => "Brunch")
    assert_equal "It changed since you read it. Find it again, then retry.", outcome[:result][:error]
    assert_equal "Lunch", caldav_item("calendar", saved[:id]).events.sole.summary.to_s
  end

  test "inviting someone outside the install waits for the person; the install's own people don't" do
    arguments = { "list" => "calendar", "title" => "Review", "start" => "2026-11-12T10:00", "invite" => [ "Sam@Elsewhere.example" ] }
    assert_equal "waiting", receive("c1", "calendar_save_event", arguments)[:status]
    assert_empty @items["calendar"]

    @conversation.invocations.find_by!(call_id: "c1").approve!(by: @maya)
    saved = run_call("c1", "calendar_save_event", arguments)[:result][:saved]
    assert_equal [ "sam@elsewhere.example" ], saved[:attendees]

    with_setting(:access, :emails, [ "maya@example.com" ]) do
      run_call("c2", "calendar_save_event", "list" => "calendar", "title" => "Plan", "start" => "2026-11-13T10:00", "invite" => [ "maya@example.com" ])
    end
    assert_equal 2, @items["calendar"].size
    run_call("c3", "calendar_save_event", "list" => "calendar", "title" => "Plan", "start" => "2026-11-13T10:00")
    assert_equal 3, @items["calendar"].size
  end

  test "a task is added, completed, and found by whether it's done and when it's due" do
    passport = run_call("c1", "calendar_save_task", "list" => "tasks", "title" => "Renew passport", "due" => "2026-11-15")[:result][:saved]
    run_call("c2", "calendar_save_task", "list" => "tasks", "title" => "Call the bank")
    run_call("c3", "calendar_save_task", "list" => "tasks", "title" => "Book flights", "due" => "2026-12-20T09:00")

    done = run_call("c4", "calendar_save_task", "list" => "tasks", "id" => passport[:id], "done" => true)[:result][:saved]
    assert done[:done]
    assert_equal "COMPLETED", caldav_item("tasks", passport[:id]).todos.sole.status.to_s

    titles = ->(arguments) { run_call("c#{arguments.hash}", "calendar_find", { "kind" => "tasks" }.merge(arguments))[:result][:tasks].pluck(:title) }
    assert_equal [ "Book flights", "Call the bank" ], titles.({})
    assert_equal [ "Renew passport", "Book flights", "Call the bank" ], titles.({ "done" => true })
    assert_equal [ "Book flights" ], titles.({ "to" => "2026-12-31" })
  end

  test "a list or id that isn't one name is refused before anything is asked" do
    outcome = run_call("c1", "calendar_delete", "list" => "../maya-2/calendar", "id" => "x")
    assert outcome[:isError]
    assert_not_requested :any, /caldav/
  end

  test "a server refusing the account says so" do
    @agent.update!(caldav_password: "wrong")
    assert_equal "The calendar server refused this agent's username and password.", run_call("c1", "calendar_lists", {})[:result][:error]
  end

  private
    def tool_names = @agent.reload.conversation.definition[:tools].pluck(:name)

    def receive(call_id, tool, arguments)
      payload = invocation_payload(@conversation, tool: tool, arguments: arguments, call_id: call_id)
      Invocation.receive(@conversation, task_id: payload[:taskId], call_id: call_id, tool: tool,
        arguments: arguments, digest: payload[:digest]).deep_symbolize_keys
    end

    def run_call(call_id, tool, arguments)
      receive(call_id, tool, arguments)
      perform_enqueued_jobs(only: InvocationCallJob)
      receive(call_id, tool, arguments)
    end
end
