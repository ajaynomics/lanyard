require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/caldav_test_helper"
require_relative "../test_helpers/passbolt_test_helper"

# A due alarm on a task in a list the agent's own account owns starts a turn
# for it (#246, docs/calendar.md, "Alarms on its own tasks"): the task's
# title, its notes and when it is due reach the thread once, however many
# runs see the alarm. A list merely shared with the account, a server it only
# reads and its linked calendar wake their own owner, not this agent.
#
# The CalDAV server (WebMock, shaped as Radicale and SabreDAV answer) and the
# sidecar are the only stand-ins; the job, the client and the thread run for real.
class TaskAlarmJobTest < ActiveJob::TestCase
  include AgentTestHelper
  include CaldavTestHelper
  include PassboltTestHelper

  DUE = "20261119T193000Z".freeze # 14:30 in Toronto
  ALARM = Time.utc(2026, 11, 19, 19, 15) # fifteen minutes before it is due

  setup do
    install_sidecar_settings
    install_caldav
    @agent = create_user(name: "Alice").agents.sole
    @agent.update!(time_zone: "Eastern Time (US & Canada)", caldav_username: "agent-1", caldav_password: "app-password")
    @conversation = create_conversation(@agent)
    @submissions = []
    record_submissions("12", @submissions)
  end

  teardown do
    remove_fake_passbolt
    remove_caldav
    remove_sidecar_settings
  end

  test "an alarm on a task in a list its own account owns wakes it once, with the title, notes, due time and list" do
    caldav_put("tasks", "plumber", task_ics(summary: "Call the plumber", notes: "Ask about the tap"))

    travel_to(ALARM + 30.seconds) { sweep }

    content = @submissions.sole["content"]
    assert_match(/\A\[Task alarm from your tasks list\./, content)
    assert_match Conversation::UNTRUSTED.strip, content, "a task is written on a phone, not instructions from the person"
    assert_match "Call the plumber", words(content)
    assert_match "Ask about the tap", words(content)
    assert_match "2026-11-19 14:30 EST (19:30Z)", words(content)
    assert_match "tasks", words(content)
  end

  test "a later run of the same alarm does not wake it again" do
    caldav_put("tasks", "plumber", task_ics(summary: "Call the plumber"))

    travel_to(ALARM + 30.seconds) { sweep }
    travel_to(ALARM + 3.minutes) { sweep }

    assert_equal 1, @submissions.size
  end

  test "an alarm on a list only shared with its account does not wake it" do
    share_caldav_list("robin", title: "Robin's tasks", owner: "/robin/")
    caldav_put("robin", "school", task_ics(summary: "Robin's school run"))

    travel_to(ALARM + 30.seconds) { sweep }

    assert_empty @submissions
  end

  test "a task that is done or cancelled does not wake it" do
    caldav_put("tasks", "done", task_ics(summary: "Already done", status: "COMPLETED"))
    caldav_put("tasks", "off", task_ics(summary: "Called off", status: "CANCELLED"))

    travel_to(ALARM + 30.seconds) { sweep }

    assert_empty @submissions
  end

  test "a busy agent is woken on a later run, once" do
    caldav_put("tasks", "plumber", task_ics(summary: "Call the plumber"))

    travel_to(ALARM + 30.seconds) do
      @conversation.update!(status: "running")
      sweep
      assert_empty @submissions, "a working agent is not interrupted"

      @conversation.update!(status: "idle")
      sweep
      sweep
    end

    assert_equal 1, @submissions.size
  end

  test "an agent whose calendar server refuses it does not hold up the others" do
    caldav_put("tasks", "plumber", task_ics(summary: "Call the plumber"))
    refused = create_conversation(@agent, durable_id: "13").agent
    refused.update!(time_zone: "UTC", caldav_username: "agent-2", caldav_password: "wrong-password")
    other = []
    record_submissions("13", other)

    travel_to(ALARM + 30.seconds) do
      assert_enqueued_with(job: TaskAlarmJob, args: [ refused ]) { TaskAlarmSweepJob.perform_now }
      assert_nothing_raised { perform_enqueued_jobs(only: TaskAlarmJob) }
    end

    assert_equal 1, @submissions.size
    assert_empty other
  end

  test "an absolute trigger and one before the start fire; a place's alarm and one outside the lookback do not" do
    caldav_put("tasks", "absolute", task_ics(summary: "Absolute", trigger: "TRIGGER;VALUE=DATE-TIME:20261119T191500Z"))
    caldav_put("tasks", "start", task_ics(summary: "From the start", start: DUE, trigger: "TRIGGER;RELATED=START:-PT15M"))
    caldav_put("tasks", "place", place_task_ics)
    caldav_put("tasks", "stale", task_ics(summary: "Yesterday", due: "20261118T193000Z"))

    travel_to(ALARM + 30.seconds) { sweep }

    woken = @submissions.map { words(it["content"]) }.join("\n")
    assert_equal 2, @submissions.size, woken
    assert_match "Absolute", woken
    assert_match "From the start", woken
  end

  test "its own calendar server's tasks wake it; a server it only reads does not" do
    install_fake_passbolt(name: "Desk calendar", uri: OWN_SERVER)
    @agent.create_calendar_server!(url: OWN_SERVER + OWN_HOME, vault_entry: "Desk calendar")
    @agent.calendar_servers.create!(read_only: true, url: OWN_SERVER + READ_ONLY_HOME, vault_entry: "Desk calendar")
    own_server

    travel_to(ALARM + 30.seconds) { sweep }

    assert_equal 1, @submissions.size
    assert_match "Order the paper", words(@submissions.sole["content"])
  end

  private
    OWN_SERVER = "https://dav.mail.example.com".freeze
    OWN_HOME = "/dav/calendars/desk/".freeze
    READ_ONLY_HOME = "/dav/calendars/old/".freeze

    def sweep = perform_enqueued_jobs(only: TaskAlarmJob) { TaskAlarmSweepJob.perform_now }

    def record_submissions(durable_id, into)
      stub_request(:post, "#{SIDECAR}/v1/conversations/#{durable_id}/submissions").to_return { |request|
        into << JSON.parse(request.body)
        { status: 202, body: { id: 1, status: "queued" }.to_json } }
      stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/#{durable_id}/entries}).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
    end

    # A task as a phone or calendar_save_task writes one: a reminder fifteen
    # minutes before it is due, folded as servers fold long lines.
    def task_ics(summary:, notes: nil, due: DUE, start: nil, status: "NEEDS-ACTION", trigger: "TRIGGER;RELATED=END:-PT15M")
      <<~ICS
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//durable-assistants//EN
        BEGIN:VTODO
        UID:#{summary.parameterize}@durable-assistants
        SUMMARY:#{summary}
        #{"DESCRIPTION:#{notes}\n" if notes}DUE:#{due}
        #{"DTSTART:#{start}\n" if start}STATUS:#{status}
        BEGIN:VALARM
        ACTION:DISPLAY
        DESCRIPTION:#{summary}
        #{trigger}
        END:VALARM
        END:VTODO
        END:VCALENDAR
      ICS
    end

    # A reminder that fires on arriving somewhere, as iOS Reminders stores it
    # (Tool::Calendar::Place): its trigger is Reminders' own time, long past.
    def place_task_ics
      <<~ICS
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//durable-assistants//EN
        BEGIN:VTODO
        UID:place@durable-assistants
        SUMMARY:Buy milk
        DUE:#{DUE}
        STATUS:NEEDS-ACTION
        BEGIN:VALARM
        ACTION:DISPLAY
        DESCRIPTION:Reminder
        TRIGGER;VALUE=DATE-TIME:#{Tool::Calendar::Place::TRIGGER}
        UID:place-alarm
        X-APPLE-PROXIMITY:ARRIVE
        X-APPLE-STRUCTURED-LOCATION;VALUE=URI;X-TITLE=The shop:geo:43.6,-79.3
        END:VALARM
        END:VTODO
        END:VCALENDAR
      ICS
    end

    # The agent's own calendar server: a home it owns with one task list, and
    # beside it a colleague's home it only reads, each holding a due alarm.
    def own_server
      items = { OWN_HOME => task_ics(summary: "Order the paper"), READ_ONLY_HOME => task_ics(summary: "Their own errand") }
      stub_request(:any, /\A#{Regexp.escape(OWN_SERVER)}/).to_return do |request|
        home = items.keys.find { request.uri.path.start_with?(it) }
        case request.method
        when :propfind
          multistatus([ collection(home, "Desk", nil, owner: home), collection("#{home}todo/", "Desk to do", "VTODO", owner: home) ])
        when :report then multistatus([ item("#{home}todo/one.ics", %("e1"), items.fetch(home)) ])
        end
      end
    end
end
