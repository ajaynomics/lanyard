require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# calendar_find against a real Radicale (docs/calendar.md), opt in as
# radicale_location_test.rb says. Radicale before 3.9.0 checks a
# non-repeating event with a TZID against an expanded range by its wall-clock
# time read as UTC, so a short window in a zone behind UTC missed it.
class RadicaleCalendarFindTest < ActiveSupport::TestCase
  include AgentTestHelper
  include ActiveJob::TestHelper

  setup do
    skip "set RADICALE_URL to a throwaway Radicale to run this" unless ENV["RADICALE_URL"]
    @previous_url = Rails.application.config.x.caldav[:url]
    Rails.application.config.x.caldav[:url] = ENV["RADICALE_URL"]
    @account = "agent-#{SecureRandom.hex(4)}"
    @agent = create_user(name: "Avery").agents.sole
    @agent.update!(caldav_username: @account, caldav_password: "any-password", time_zone: "Pacific Time (US & Canada)")
    @conversation = create_conversation(@agent)
    radicale(Class.new(Net::HTTPRequest) { const_set(:METHOD, "MKCALENDAR"); const_set(:REQUEST_HAS_BODY, false); const_set(:RESPONSE_HAS_BODY, true) }, "calendar-avery/")
  end

  teardown do
    Rails.application.config.x.caldav[:url] = @previous_url if ENV["RADICALE_URL"]
  end

  test "an event inside a one-hour window on a named list comes back, saved here or by a phone" do
    save("c1", "Call with Avery", "2026-11-23T10:30", "2026-11-23T10:45")
    save("c2", "Walk with Avery", "2026-11-23T11:00", "2026-11-23T11:30")
    save("c3", "Standup", "2026-11-20T09:00", "2026-11-20T09:15", "repeat" => "FREQ=DAILY")
    radicale(Net::HTTP::Put, "calendar-avery/phone-1.ics", phone_event("Coffee with Avery", "20261123T100000", "20261123T102000"))
    radicale(Net::HTTP::Put, "calendar-avery/phone-2.ics", phone_event("Early run", "20261123T063000", "20261123T070000"))

    assert_equal [ "Coffee with Avery", "Call with Avery" ], titles("2026-11-23T10:00", "2026-11-23T11:00")
    assert_equal [ "Early run", "Standup", "Coffee with Avery", "Call with Avery", "Walk with Avery" ], titles("2026-11-23", "2026-11-24")
  end

  private
    def titles(from, to)
      found = run_call("f-#{from}", "calendar_find", "kind" => "events", "list" => "calendar-avery", "from" => from, "to" => to)
      found.dig(:result, :events).pluck(:title)
    end

    def save(call_id, title, start, finish, more = {})
      run_call(call_id, "calendar_save_event", { "list" => "calendar-avery", "title" => title, "start" => start, "end" => finish }.merge(more))[:result].fetch(:saved)
    end

    # As an iPhone writes one: its own VTIMEZONE and TZID.
    def phone_event(title, start, finish)
      <<~ICS.gsub("\n", "\r\n")
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Apple Inc.//iOS 26.1//EN
        BEGIN:VTIMEZONE
        TZID:America/Los_Angeles
        BEGIN:DAYLIGHT
        DTSTART:20070311T020000
        RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU
        TZOFFSETFROM:-0800
        TZOFFSETTO:-0700
        TZNAME:PDT
        END:DAYLIGHT
        BEGIN:STANDARD
        DTSTART:20071104T020000
        RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU
        TZOFFSETFROM:-0700
        TZOFFSETTO:-0800
        TZNAME:PST
        END:STANDARD
        END:VTIMEZONE
        BEGIN:VEVENT
        UID:#{SecureRandom.uuid}
        DTSTAMP:20261120T120000Z
        DTSTART;TZID=America/Los_Angeles:#{start}
        DTEND;TZID=America/Los_Angeles:#{finish}
        SUMMARY:#{title}
        END:VEVENT
        END:VCALENDAR
      ICS
    end

    def radicale(kind, path, body = nil)
      uri = URI.join(ENV["RADICALE_URL"].delete_suffix("/") + "/", "#{@account}/#{path}")
      request = kind.new(uri, body ? { "Content-Type" => "text/calendar; charset=utf-8" } : {}).tap { it.basic_auth(@account, "any-password") }
      request.body = body if body
      Net::HTTP.start(uri.host, uri.port) { it.request(request) }.tap { assert it.is_a?(Net::HTTPSuccess), "#{kind::METHOD} #{path}: HTTP #{it.code}" }
    end

    def run_call(call_id, tool, arguments)
      payload = invocation_payload(@conversation, tool: tool, arguments: arguments, call_id: call_id)
      receive = -> { Invocation.receive(@conversation, task_id: payload[:taskId], call_id: call_id, tool: tool, arguments: arguments, digest: payload[:digest]).deep_symbolize_keys }
      receive.()
      perform_enqueued_jobs(only: InvocationCallJob)
      receive.()
    end
end
