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
    assert_equal Tool::Catalog::CALENDAR.map(&:tool_name), tool_names & Tool::Catalog::CALENDAR.map(&:tool_name), "in every message (Tool::Catalog::CORE)"
    with_setting(:caldav, :url, nil) { assert_not_includes tool_names, "calendar_find" }
    @agent.update!(caldav_password: nil)
    assert_not_includes tool_names, "calendar_find"
  end

  test "the app password is kept encrypted" do
    assert_not_includes Agent.connection.select_value("select caldav_password from agents where id = #{@agent.id}"), "app-password"
  end

  test "lists come by the name the other tools take" do
    assert_equal [ { list: "calendar", name: "Maya's calendar", kinds: [ "events" ], own: true }, { list: "tasks", name: "Maya's tasks", kinds: [ "tasks" ], own: true } ],
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

  test "an event is free or busy: a new one busy unless said, a change leaving it as it was unless named" do
    busy = run_call("c1", "calendar_save_event", "list" => "calendar", "title" => "Lunch", "start" => "2026-11-12T12:00")[:result][:saved]
    assert_equal false, busy[:free]
    assert_match(/^TRANSP:OPAQUE\r?$/, @items["calendar"][busy[:id]].last)

    free = run_call("c2", "calendar_save_event", "list" => "calendar", "title" => "Focus", "start" => "2026-11-12T14:00", "free" => true)[:result][:saved]
    assert_equal true, free[:free]
    assert_match(/^TRANSP:TRANSPARENT\r?$/, @items["calendar"][free[:id]].last)

    run_call("c3", "calendar_save_event", "list" => "calendar", "id" => busy[:id], "free" => true)
    assert_equal "TRANSPARENT", caldav_item("calendar", busy[:id]).events.sole.transp.to_s
    run_call("c4", "calendar_save_event", "list" => "calendar", "id" => free[:id], "free" => false)
    assert_equal "OPAQUE", caldav_item("calendar", free[:id]).events.sole.transp.to_s

    found = run_call("c5", "calendar_find", "kind" => "events", "from" => "2026-11-12", "to" => "2026-11-13")[:result][:events]
    assert_equal [ [ "Lunch", true ], [ "Focus", false ] ], found.map { it.values_at(:title, :free) }
  end

  test "changing an event without naming free leaves its TRANSP exactly as a phone wrote it" do
    caldav_put "calendar", "phone-2", <<~ICS.gsub("\n", "\r\n")
      BEGIN:VCALENDAR
      VERSION:2.0
      PRODID:-//Apple Inc.//iOS 26//EN
      BEGIN:VEVENT
      UID:phone-2
      DTSTAMP:20261101T120000Z
      DTSTART:20261117T140000Z
      DTEND:20261117T150000Z
      SUMMARY:Out of office
      TRANSP:TRANSPARENT
      END:VEVENT
      END:VCALENDAR
    ICS
    saved = run_call("c1", "calendar_save_event", "list" => "calendar", "id" => "phone-2", "title" => "Away", "start" => "2026-11-17T10:00")[:result][:saved]
    assert_equal true, saved[:free]
    stored = @items["calendar"]["phone-2"].last
    assert_match "SUMMARY:Away", stored
    assert_equal 1, stored.scan(/^TRANSP:/).size
    assert_match(/^TRANSP:TRANSPARENT\r?$/, stored)

    caldav_put "calendar", "phone-3", <<~ICS.gsub("\n", "\r\n")
      BEGIN:VCALENDAR
      VERSION:2.0
      PRODID:-//Apple Inc.//iOS 26//EN
      BEGIN:VEVENT
      UID:phone-3
      DTSTAMP:20261101T120000Z
      DTSTART:20261118T140000Z
      DTEND:20261118T150000Z
      SUMMARY:No TRANSP at all
      END:VEVENT
      END:VCALENDAR
    ICS
    saved = run_call("c2", "calendar_save_event", "list" => "calendar", "id" => "phone-3", "title" => "Still none")[:result][:saved]
    assert_equal false, saved[:free], "no TRANSP is opaque (RFC 5545)"
    assert_no_match(/^TRANSP/, @items["calendar"]["phone-3"].last)
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

  test "a task's reminder, saved by the agent, is read back by calendar_find" do
    run_call("c1", "calendar_save_task", "list" => "tasks", "title" => "Pay rent", "due" => "2026-11-20T09:00", "alarm_minutes" => 15)

    task = run_call("c2", "calendar_find", "kind" => "tasks")[:result][:tasks].sole
    assert_equal [ { minutes: 15, before: "due", action: "display" } ], task[:alarms]
  end

  test "calendar_find shows each alarm as a phone wrote it: before or after the start or end, or at a time" do
    caldav_put("calendar", "standup", <<~ICS.gsub("\n", "\r\n"))
      BEGIN:VCALENDAR
      VERSION:2.0
      PRODID:-//Example Phone//EN
      BEGIN:VEVENT
      UID:standup@example.com
      DTSTAMP:20261101T120000Z
      DTSTART:20261112T150000Z
      DTEND:20261112T160000Z
      SUMMARY:Standup
      BEGIN:VALARM
      ACTION:DISPLAY
      DESCRIPTION:Standup
      TRIGGER:-PT10M
      END:VALARM
      BEGIN:VALARM
      ACTION:AUDIO
      TRIGGER;RELATED=END:PT5M
      END:VALARM
      BEGIN:VALARM
      ACTION:EMAIL
      DESCRIPTION:Standup
      SUMMARY:Standup
      ATTENDEE:mailto:someone@example.com
      TRIGGER;VALUE=DATE-TIME:20261112T130000Z
      END:VALARM
      BEGIN:VALARM
      ACTION:NONE
      TRIGGER;VALUE=DATE-TIME:19760401T005545Z
      END:VALARM
      END:VEVENT
      END:VCALENDAR
    ICS
    caldav_put("tasks", "milk", <<~ICS.gsub("\n", "\r\n"))
      BEGIN:VCALENDAR
      VERSION:2.0
      PRODID:-//Example Phone//EN
      BEGIN:VTODO
      UID:milk@example.com
      DTSTAMP:20261101T120000Z
      DUE:20261113T170000Z
      SUMMARY:Buy milk
      BEGIN:VALARM
      ACTION:DISPLAY
      DESCRIPTION:Reminder
      TRIGGER:PT0S
      END:VALARM
      BEGIN:VALARM
      ACTION:DISPLAY
      DESCRIPTION:Reminder
      TRIGGER;RELATED=END:-P1D
      END:VALARM
      END:VTODO
      END:VCALENDAR
    ICS

    event = run_call("c1", "calendar_find", "kind" => "events", "from" => "2026-11-12", "to" => "2026-11-13")[:result][:events].sole
    assert_equal [ { minutes: 10, before: "start", action: "display" }, { minutes: 5, after: "end", action: "audio" },
      { at: "2026-11-12T08:00:00-05:00", action: "email" } ], event[:alarms], "an alarm set never to fire (ACTION:NONE) is not shown"

    task = run_call("c2", "calendar_find", "kind" => "tasks")[:result][:tasks].sole
    assert_equal [ { minutes: 0, before: "due", action: "display" }, { minutes: 1440, before: "due", action: "display" } ], task[:alarms],
      "a task with no start counts every alarm from its due time, as it fires (Agent::Alarm)"
  end

  test "an event with no alarms shows none" do
    run_call("c1", "calendar_save_event", "list" => "calendar", "title" => "Lunch", "start" => "2026-11-12T12:00")
    event = run_call("c2", "calendar_find", "kind" => "events", "from" => "2026-11-12", "to" => "2026-11-13")[:result][:events].sole
    assert_not event.key?(:alarms)
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

  # A live install's case: two changes to a task (its due date and notes, then
  # done) failed in a second, and all the agent or anyone running the install
  # was told was the error's class. The read before the write had failed.
  test "a change the server fails before anything is written says why and that nothing changed, and logs no content" do
    task = run_call("c1", "calendar_save_task", "list" => "tasks", "title" => "Renew passport", "due" => "2026-11-15")[:result][:saved]
    stub_request(:get, /#{task[:id]}/).to_return(status: 500)

    log = warnings do
      @changed = run_call("c2", "calendar_save_task", "list" => "tasks", "id" => task[:id], "due" => "2026-11-20", "notes" => "Bring the old one")
      @done = run_call("c3", "calendar_save_task", "list" => "tasks", "id" => task[:id], "done" => true)
    end

    said = "The calendar server couldn't read #{task[:id]} (HTTP 500). Nothing was changed."
    assert_equal [ said, said ], [ @changed, @done ].map { it[:result][:error] }
    assert_equal [ "Renew passport", Date.new(2026, 11, 15), nil, nil ], caldav_item("tasks", task[:id]).todos.sole.then { [ it.summary.to_s, it.due.to_date, it.description, it.completed ] }
    invocations = @conversation.invocations.where(call_id: %w[ c2 c3 ]).order(:call_id)
    assert_equal invocations.map { "Invocation #{it.id}: calendar_save_task failed: DurableAssistants::Caldav::Error (HTTP 500)" }, log.lines.map(&:chomp)
  end

  test "a server it can't reach before anything is written says so, and that nothing changed" do
    task = run_call("c1", "calendar_save_task", "list" => "tasks", "title" => "Renew passport")[:result][:saved]
    stub_request(:get, /#{task[:id]}/).to_raise(Errno::ECONNREFUSED)

    log = warnings { @done = run_call("c2", "calendar_save_task", "list" => "tasks", "id" => task[:id], "done" => true) }

    assert_equal "Could not reach the calendar server (ECONNREFUSED). Nothing was changed.", @done[:result][:error]
    assert_match(/calendar_save_task failed: DurableAssistants::Caldav::Error\n\z/, log)
  end

  test "a write the server refuses says so, and why, in a line anyone running the install can read" do
    task = run_call("c1", "calendar_save_task", "list" => "tasks", "title" => "Renew passport")[:result][:saved]
    stub_request(:put, /#{task[:id]}/).to_return(status: 412)

    log = warnings { @done = run_call("c2", "calendar_save_task", "list" => "tasks", "id" => task[:id], "done" => true) }

    assert_equal "It changed since you read it. Find it again, then retry.", @done[:result][:error]
    assert_match(/calendar_save_task failed: DurableAssistants::Caldav::Error \(HTTP 412\)\n\z/, log)
  end

  # A server that fails or goes quiet after taking a save leaves the agent
  # guessing; a guess that it didn't land makes a second copy. So the item is
  # read back, and what it shows is said.
  test "a change the server took but answered 500 to is read back and reported saved" do
    task = run_call("c1", "calendar_save_task", "list" => "tasks", "title" => "Renew passport")[:result][:saved]
    stub_request(:put, /#{task[:id]}/).to_return { caldav_answer(it) and { status: 500 } }

    done = run_call("c2", "calendar_save_task", "list" => "tasks", "id" => task[:id], "done" => true)[:result]

    assert_nil done[:error]
    assert_equal true, done[:saved][:done]
    assert_equal [ "COMPLETED" ], @items["tasks"].keys.map { caldav_item("tasks", it).todos.sole.status.to_s }
  end

  test "a new event the server took but answered 500 to is reported saved, so it is not made twice" do
    stub_request(:put, %r{/calendar/}).to_return { caldav_answer(it) and { status: 502 } }

    saved = run_call("c1", "calendar_save_event", "list" => "calendar", "title" => "Dentist", "start" => "2026-11-12T15:00")[:result]

    assert_nil saved[:error]
    assert_equal [ saved[:saved][:id] ], @items["calendar"].keys
  end

  test "a change the server answered 500 to and did not take says so, and that it is safe to try again" do
    task = run_call("c1", "calendar_save_task", "list" => "tasks", "title" => "Renew passport")[:result][:saved]
    stub_request(:put, /#{task[:id]}/).to_return(status: 500)

    done = run_call("c2", "calendar_save_task", "list" => "tasks", "id" => task[:id], "done" => true)[:result]

    assert_equal "The calendar server couldn't save #{task[:id]} (HTTP 500). Reading it back shows it did not land, so it is safe to try again.", done[:error]
    assert_equal "", caldav_item("tasks", task[:id]).todos.sole.status.to_s
  end

  test "a new task the server answered 500 to and did not take says so, and that it is safe to try again" do
    stub_request(:put, %r{/tasks/}).to_return(status: 500)

    added = run_call("c1", "calendar_save_task", "list" => "tasks", "title" => "Renew passport")[:result]

    assert_match(/\AThe calendar server couldn't save \S+ \(HTTP 500\)\. Reading it back shows it did not land, so it is safe to try again\.\z/, added[:error])
    assert_empty @items["tasks"]
  end

  test "a save that timed out is read back: saved if it landed, safe to try again if not" do
    task = run_call("c1", "calendar_save_task", "list" => "tasks", "title" => "Renew passport")[:result][:saved]
    stub_request(:put, /#{task[:id]}/).to_raise(Net::ReadTimeout)
    lost = run_call("c2", "calendar_save_task", "list" => "tasks", "id" => task[:id], "done" => true)[:result]
    assert_equal "Could not reach the calendar server (ReadTimeout). Reading it back shows it did not land, so it is safe to try again.", lost[:error]

    stub_request(:put, /#{task[:id]}/).to_return { caldav_answer(it) and raise Net::ReadTimeout }
    landed = run_call("c3", "calendar_save_task", "list" => "tasks", "id" => task[:id], "done" => true)[:result]
    assert_nil landed[:error]
    assert_equal "COMPLETED", caldav_item("tasks", task[:id]).todos.sole.status.to_s
  end

  test "a change still in doubt after the read back fails keeps 'may or may not', and to check first" do
    task = run_call("c1", "calendar_save_task", "list" => "tasks", "title" => "Renew passport")[:result][:saved]
    stub_request(:put, /#{task[:id]}/).to_return(status: 500)
    stub_request(:get, /#{task[:id]}/).to_return(status: 200, body: @items["tasks"][task[:id]].last, headers: { "ETag" => @items["tasks"][task[:id]].first }).then.to_return(status: 503)

    log = warnings { @done = run_call("c2", "calendar_save_task", "list" => "tasks", "id" => task[:id], "done" => true) }

    assert_equal "The calendar server couldn't save #{task[:id]} (HTTP 500). Reading it back failed too, " \
      "so it may or may not have happened; check before trying again.", @done[:result][:error]
    assert_match(/calendar_save_task failed: DurableAssistants::Caldav::Error \(HTTP 500\)\n\z/, log)
  end

  test "a server that refused the connection took nothing, so nothing is read back" do
    task = run_call("c1", "calendar_save_task", "list" => "tasks", "title" => "Renew passport")[:result][:saved]
    stub_request(:put, /#{task[:id]}/).to_raise(Errno::ECONNREFUSED)

    done = run_call("c2", "calendar_save_task", "list" => "tasks", "id" => task[:id], "done" => true)[:result]

    assert_equal "Could not reach the calendar server (ECONNREFUSED).", done[:error]
    assert_requested :get, /#{task[:id]}/, times: 1
  end

  # Radicale before 3.9.0 (docs/calendar.md) answers an expanded REPORT by
  # each non-repeating event's wall-clock time read as UTC; this fake does the
  # same, so the search must still find what lies in the range it was asked.
  test "a short window finds what is in it, though the server matches local times as UTC" do
    @agent.update!(time_zone: "Pacific Time (US & Canada)")
    { "in" => [ "1030", "1045" ], "at-start" => [ "1000", "1020" ], "ends-at-start" => [ "0930", "1000" ], "far" => [ "2030", "2045" ] }.each do |id, (from, to)|
      caldav_put "calendar", id, <<~ICS.gsub("\n", "\r\n")
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Apple Inc.//iOS 26//EN
        BEGIN:VEVENT
        UID:#{id}
        DTSTAMP:20261101T120000Z
        DTSTART;TZID=America/Los_Angeles:20261123T#{from}00
        DTEND;TZID=America/Los_Angeles:20261123T#{to}00
        SUMMARY:#{id}
        END:VEVENT
        END:VCALENDAR
      ICS
    end
    def self.caldav_answer(request)
      return super unless request.method == :report
      start, finish = request.body.scan(/start="(\d{8}T\d{6})Z" end="(\d{8}T\d{6})Z"/).first.map { Time.utc(*it.unpack("A4A2A2xA2A2A2").map(&:to_i)) }
      matched = @caldav_items["calendar"].select do |_, (_, ics)|
        event = Icalendar::Calendar.parse(ics).first.events.sole
        wall = ->(time) { Time.utc(*time.value.strftime("%Y %m %d %H %M").split.map(&:to_i)) }
        wall.(event.dtstart) < finish && wall.(event.dtend) > start
      end
      multistatus(matched.map { |key, (etag, ics)| item("/agent-1/calendar/#{key}.ics", etag, ics) })
    end

    found = run_call("c1", "calendar_find", "kind" => "events", "list" => "calendar", "from" => "2026-11-23T10:00", "to" => "2026-11-23T11:00")[:result][:events]
    assert_equal [ "at-start", "in" ], found.pluck(:title)
  end

  private
    def tool_names = @agent.reload.conversation.definition[:tools].pluck(:name)

    # Only what is logged as a warning or worse: SQL and job lines, at debug
    # and info, carry their own values.
    def warnings
      output = StringIO.new
      Rails.logger.broadcast_to(listener = ActiveSupport::Logger.new(output).tap { it.level = :warn })
      yield
      output.string
    ensure
      Rails.logger.stop_broadcasting_to(listener)
    end

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
