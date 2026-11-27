require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/caldav_test_helper"
require_relative "../test_helpers/passbolt_test_helper"

# A due alarm on an event or a task in a list the agent's own account owns
# is mailed to the agent's own address from the install's do-not-reply
# address (docs/calendar.md, "Alarms on its own lists"): one message an
# alarm, once, however many runs see it, and one for those missed while
# nothing ran. A list merely shared with the account, a server it only reads
# and its linked calendar are their own owner's, not this agent's.
#
# The CalDAV server (WebMock, shaped as Radicale and SabreDAV answer) is the
# only stand-in; the jobs, the client and the mailer run for real.
class AlarmMailerJobTest < ActiveJob::TestCase
  include AgentTestHelper
  include CaldavTestHelper
  include PassboltTestHelper

  DUE = "20261119T193000Z".freeze # 14:30 in Toronto
  ALARM = Time.utc(2026, 11, 19, 19, 15) # fifteen minutes before it is due

  setup do
    install_caldav
    @agent = create_user(name: "Alice").agents.sole
    @agent.update!(time_zone: "Eastern Time (US & Canada)", caldav_username: "agent-1", caldav_password: "app-password",
      alarms_read_until: ALARM - 1.day)
    @conversation = create_conversation(@agent)
    ActionMailer::Base.deliveries.clear
  end

  teardown do
    remove_fake_passbolt
    remove_caldav
  end

  test "an alarm on a task in a list its own account owns is mailed to it once, from the do-not-reply address" do
    caldav_put("tasks", "plumber", task_ics(summary: "Call the plumber", notes: "Ask about the tap"))

    travel_to(ALARM + 30.seconds) { sweep }
    travel_to(ALARM + 3.minutes) { sweep }

    mail = mails.sole
    assert_equal [ "no-reply@agents.example" ], mail.from
    assert_equal [ "#{@agent.email_name}@agents.example" ], mail.to
    assert_equal "Call the plumber", mail.subject
    assert_match "Ask about the tap", mail.body.to_s
    assert_match "Due 2026-11-19 14:30 EST (19:30Z). It is task plumber on your tasks list.", mail.body.to_s
    assert_match(/\A<alarm\.#{@agent.id}\.\h{32}@agents\.example>\z/, "<#{mail.message_id}>")
  end

  test "an alarm while the agent is busy is mailed all the same" do
    caldav_put("tasks", "plumber", task_ics(summary: "Call the plumber"))
    @conversation.update!(status: "running")

    travel_to(ALARM + 30.seconds) { sweep }

    assert_equal [ "Call the plumber" ], mails.map(&:subject)
  end

  test "after a restart across the due time, what it missed in the last day comes in one message" do
    caldav_put("tasks", "plumber", task_ics(summary: "Call the plumber"))
    caldav_put("tasks", "bins", task_ics(summary: "Put the bins out", due: "20261119T200000Z"))
    caldav_put("tasks", "stale", task_ics(summary: "Two days ago", due: "20261117T193000Z"))
    @agent.update!(alarms_read_until: ALARM - 3.days)

    travel_to(ALARM + 2.hours) { sweep }

    mail = mails.sole
    assert_equal "2 missed reminders", mail.subject
    assert_match(/Call the plumber.*Put the bins out/m, mail.body.to_s)
    assert_no_match "Two days ago", mail.body.to_s
  end

  test "a send that fails is mailed by the next read, and the next run sends nothing more" do
    caldav_put("tasks", "plumber", task_ics(summary: "Call the plumber"))

    travel_to(ALARM + 30.seconds) { with_smtp_down { sweep } }
    assert_empty mails
    travel_to(ALARM + 90.seconds) { sweep }
    travel_to(ALARM + 150.seconds) { sweep }

    assert_equal [ "Call the plumber" ], mails.map(&:subject)
  end

  test "one alarm on two occurrences is mailed for each; a retry after a failed send mails neither again" do
    caldav_put("tasks", "stretch", task_ics(summary: "Stretch", extra: "RRULE:FREQ=MINUTELY;INTERVAL=5;COUNT=3"))
    @agent.update!(alarms_read_until: ALARM - 1.minute)

    travel_to(ALARM + 5.minutes + 30.seconds) { with_mail_server_taking(1) { sweep } }
    travel_to(ALARM + 6.minutes + 30.seconds) { sweep }
    travel_to(ALARM + 7.minutes + 30.seconds) { sweep }

    assert_equal [ "Due 2026-11-19 14:30 EST", "Due 2026-11-19 14:35 EST" ], mails.map { it.body.to_s[/Due [^(]+EST/] }
    assert_equal 2, mails.map(&:message_id).uniq.size, "each occurrence is its own alarm"
  end

  test "a reminder a day before a repeating event keeps its hour across the change of clocks" do
    # Every day at 9:00 in Toronto; on 1 November the clocks go back an hour.
    caldav_put("calendar", "standup", event_ics(summary: "Standup", start: ";TZID=America/Toronto:20261028T090000",
      finish: ";TZID=America/Toronto:20261028T093000", trigger: "TRIGGER:-P1D", extra: "RRULE:FREQ=DAILY;COUNT=10"))
    @agent.update!(alarms_read_until: Time.utc(2026, 10, 31, 12, 50))

    travel_to(Time.utc(2026, 10, 31, 13, 0, 30)) { sweep } # 9:00 EDT, a day before 9:00 EST

    assert_equal [ "Standup" ], mails.map(&:subject)
    assert_match "Starts 2026-11-01 09:00 EST (14:00Z)", mails.sole.body.to_s
  end

  test "an all-day event's reminder counts from the start of its day where the agent is" do
    caldav_put("calendar", "birthday", event_ics(summary: "Robin's birthday", start: ";VALUE=DATE:20261120", finish: ";VALUE=DATE:20261121"))
    @agent.update!(alarms_read_until: Time.utc(2026, 11, 20, 4, 40))

    travel_to(Time.utc(2026, 11, 20, 4, 45, 30)) { sweep } # 23:45 the evening before, in Toronto

    assert_match "Starts 2026-11-20, all day", mails.sole.body.to_s
  end

  test "a repeating task skips a day it excludes" do
    caldav_put("tasks", "pills", task_ics(summary: "Take the pills", extra: "RRULE:FREQ=DAILY;COUNT=5\nEXDATE:20261120T193000Z"))
    @agent.update!(alarms_read_until: ALARM + 1.day - 1.minute)

    travel_to(ALARM + 1.day + 30.seconds) { sweep }
    assert_empty mails

    travel_to(ALARM + 2.days + 30.seconds) { sweep }
    assert_match "Due 2026-11-21 14:30 EST", mails.sole.body.to_s
  end

  test "a moved occurrence fires at its new time only, once" do
    caldav_put("calendar", "review", event_ics(summary: "Review", start: ":20261119T193000Z", finish: ":20261119T200000Z",
      extra: "RRULE:FREQ=WEEKLY;COUNT=4", moved: { "20261126T193000Z" => "20261126T213000Z" }))
    @agent.update!(alarms_read_until: ALARM + 1.week - 1.minute)

    travel_to(ALARM + 1.week + 30.seconds) { sweep }
    assert_empty mails, "the occurrence it was moved from"

    travel_to(ALARM + 1.week + 2.hours + 30.seconds) { sweep }
    travel_to(ALARM + 1.week + 2.hours + 90.seconds) { sweep }
    assert_match "Starts 2026-11-26 16:30 EST", mails.sole.body.to_s
  end

  test "an alarm on a list only shared with its account, or on a task done or cancelled, is not mailed" do
    share_caldav_list("robin", title: "Robin's tasks", owner: "/robin/")
    caldav_put("robin", "school", task_ics(summary: "Robin's school run"))
    caldav_put("tasks", "done", task_ics(summary: "Already done", status: "COMPLETED"))
    caldav_put("tasks", "off", task_ics(summary: "Called off", status: "CANCELLED"))

    travel_to(ALARM + 30.seconds) { sweep }

    assert_empty mails
  end

  test "a task naming attendees reaches only the agent it names, at this install" do
    with_mail do
      caldav_put("tasks", "review", task_ics(summary: "Review the draft", attendees: [ "ATTENDEE:MAILTO:#{@agent.email_address.upcase}" ]))
      caldav_put("tasks", "other", task_ics(summary: "Someone else's", attendees: [ "ATTENDEE:mailto:#{@agent.email_name}@other-install.example" ]))
    end

    travel_to(ALARM + 30.seconds) { sweep }

    assert_equal [ "Review the draft" ], mails.map(&:subject)
  end

  test "an agent whose calendar server refuses it does not hold up the others" do
    caldav_put("tasks", "plumber", task_ics(summary: "Call the plumber"))
    refused = create_conversation(@agent, durable_id: "13").agent
    refused.update!(time_zone: "UTC", caldav_username: "agent-2", caldav_password: "wrong-password", alarms_read_until: ALARM - 1.day)

    travel_to(ALARM + 30.seconds) { assert_nothing_raised { sweep } }

    assert_equal [ "#{@agent.email_name}@agents.example" ], mails.sole.to
    assert_equal ALARM - 1.day, refused.reload.alarms_read_until, "what it could not read is read next time"
  end

  test "an absolute trigger and one before the start fire; a place's alarm and one long gone do not" do
    caldav_put("tasks", "absolute", task_ics(summary: "Absolute", trigger: "TRIGGER;VALUE=DATE-TIME:20261119T191500Z"))
    caldav_put("tasks", "start", task_ics(summary: "From the start", start: DUE, trigger: "TRIGGER;RELATED=START:-PT15M"))
    caldav_put("tasks", "place", place_task_ics)
    @agent.update!(alarms_read_until: ALARM - 1.minute)
    caldav_put("tasks", "stale", task_ics(summary: "Yesterday", due: "20261118T193000Z"))

    travel_to(ALARM + 30.seconds) { sweep }

    assert_equal [ "Absolute", "From the start" ], mails.map(&:subject).sort
  end

  test "its own calendar server's tasks are mailed; a server it only reads is not" do
    install_fake_passbolt(name: "Desk calendar", uri: OWN_SERVER)
    @agent.create_calendar_server!(url: OWN_SERVER + OWN_HOME, vault_entry: "Desk calendar")
    @agent.calendar_servers.create!(read_only: true, url: OWN_SERVER + READ_ONLY_HOME, vault_entry: "Desk calendar")
    own_server

    travel_to(ALARM + 30.seconds) { sweep }

    assert_equal [ "Order the paper" ], mails.map(&:subject)
  end

  test "an agent's first read mails nothing and starts from then" do
    caldav_put("tasks", "plumber", task_ics(summary: "Call the plumber"))
    @agent.update!(alarms_read_until: nil)

    travel_to(ALARM + 30.seconds) { sweep }

    assert_empty mails
    assert_equal ALARM + 30.seconds, @agent.reload.alarms_read_until
  end

  private
    OWN_SERVER = "https://dav.mail.example.com".freeze
    OWN_HOME = "/dav/calendars/desk/".freeze
    READ_ONLY_HOME = "/dav/calendars/old/".freeze

    def sweep = with_mail { perform_enqueued_jobs(only: AlarmMailerJob) { AlarmSweepJob.perform_now } }

    def mails = ActionMailer::Base.deliveries

    # A mail server that takes `count` messages, then refuses the rest, as one
    # going down in the middle of a run.
    class MailServer < Struct.new(:settings)
      def deliver!(mail) = settings[:taken].shift ? ActionMailer::Base.deliveries << mail : raise(Net::SMTPServerBusy, "busy")
    end
    ActionMailer::Base.add_delivery_method :failing_midway, MailServer

    def with_mail_server_taking(count)
      AlarmMailer.delivery_method, AlarmMailer.failing_midway_settings = :failing_midway, { taken: [ true ] * count }
      yield
    ensure
      AlarmMailer.delivery_method = :test
    end

    # A mail server that refuses the connection: nothing listens on the port.
    def with_smtp_down
      AlarmMailer.delivery_method, AlarmMailer.smtp_settings = :smtp, { address: "127.0.0.1", port: 9 }
      yield
    ensure
      AlarmMailer.delivery_method, AlarmMailer.smtp_settings = :test, ActionMailer::Base.smtp_settings
    end

    def with_mail(&block)
      with_setting(:mail, :domain, "agents.example") do
        with_setting(:mail, :smtp_address, "smtp.agents.example", &block)
      end
    end

    # A task as a phone or calendar_save_task writes one: a reminder fifteen
    # minutes before it is due.
    def task_ics(summary:, notes: nil, due: DUE, start: nil, status: "NEEDS-ACTION", trigger: "TRIGGER;RELATED=END:-PT15M", attendees: [], extra: nil)
      calendar(<<~ICS)
        BEGIN:VTODO
        UID:#{summary.parameterize}@durable-assistants
        SUMMARY:#{summary}
        #{"DESCRIPTION:#{notes}\n" if notes}DUE:#{due}
        #{"DTSTART:#{start}\n" if start}#{"#{attendees.join("\n")}\n" if attendees.any?}#{"#{extra}\n" if extra}STATUS:#{status}
        #{alarm(summary, trigger)}
        END:VTODO
      ICS
    end

    # An event as a phone stores it, with any occurrence moved to another
    # time beside it under the same UID, as RFC 5545 keeps an override.
    def event_ics(summary:, start:, finish:, trigger: "TRIGGER:-PT15M", extra: nil, moved: {})
      overrides = moved.map do |from, to|
        "BEGIN:VEVENT\nUID:#{summary.parameterize}\nRECURRENCE-ID:#{from}\nDTSTART:#{to}\nSUMMARY:#{summary}\n#{alarm(summary, trigger)}\nEND:VEVENT"
      end
      calendar(<<~ICS)
        BEGIN:VEVENT
        UID:#{summary.parameterize}
        SUMMARY:#{summary}
        DTSTART#{start}
        DTEND#{finish}
        #{"#{extra}\n" if extra}#{alarm(summary, trigger)}
        END:VEVENT
        #{overrides.join("\n")}
      ICS
    end

    def alarm(summary, trigger) = "BEGIN:VALARM\nACTION:DISPLAY\nDESCRIPTION:#{summary}\n#{trigger}\nEND:VALARM"

    def calendar(components) = "BEGIN:VCALENDAR\nVERSION:2.0\nPRODID:-//durable-assistants//EN\n#{components.gsub(/^\n/, "")}END:VCALENDAR\n"

    # A reminder that fires on arriving somewhere, as iOS Reminders stores it
    # (Tool::Calendar::Place): its trigger is Reminders' own time, long past.
    def place_task_ics
      task_ics(summary: "Buy milk", trigger: "TRIGGER;VALUE=DATE-TIME:#{Tool::Calendar::Place::TRIGGER}\nUID:place-alarm\n" \
        "X-APPLE-PROXIMITY:ARRIVE\nX-APPLE-STRUCTURED-LOCATION;VALUE=URI;X-TITLE=The shop:geo:43.6,-79.3")
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
