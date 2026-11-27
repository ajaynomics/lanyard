require "test_helper"
require "ipaddr"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/passbolt_test_helper"

# Test-only opt-in: point EVENT_ONLY_RADICALE_FIXTURE at the private TLS edge
# for a fresh stock Radicale. The edge seeds ITEM, exposes /ready and /trace,
# and labels independent fixture requests without changing Radicale's answers.
class EventOnlyCalendarRadicaleTest < ActiveSupport::TestCase
  include AgentTestHelper, PassboltTestHelper, ActiveJob::TestHelper

  COLLECTION = "/fixture/events/"
  ITEM = "#{COLLECTION}tool-event.ics"
  LIST = "events"
  RANGE = { "from" => "2026-11-20T00:00:00Z", "to" => "2026-11-21T00:00:00Z" }.freeze
  STRONG_ETAG = /\A"[\x21\x23-\x7e]+"\z/

  setup do
    skip "requires the isolated EVENT_ONLY_RADICALE_FIXTURE" unless ENV["EVENT_ONLY_RADICALE_FIXTURE"]
    @edge = URI(ENV.fetch("EVENT_ONLY_RADICALE_FIXTURE"))
    host = IPAddr.new(@edge.host.to_s)
    assert @edge.is_a?(URI::HTTPS) && host.ipv4? && host.private? && @edge.port == 8443
    assert_equal "https://#{host}:8443", @edge.to_s
    WebMock.disable_net_connect!(allow: "#{host}:8443")
    @allowed_edge = true
    assert_equal "isolated-stock-radicale-tool-fixture", fixture_request(Net::HTTP::Get, "/ready").body

    entry = "Synthetic calendar fixture"
    install_fake_passbolt(name: entry, uri: @edge.to_s, username: "fixture", password: "synthetic-fixture-value")
    @agent = create_user(name: "CalendarOwner", email: "fixture@example.invalid").agents.sole
    @agent.create_calendar_server!(vault_entry: entry, collection_urls: "#{@edge}#{COLLECTION}")
    @conversation = create_conversation(@agent)
  end

  teardown do
    remove_fake_passbolt
    WebMock.disable_net_connect!(allow_localhost: true) if @allowed_edge
  end

  test "find discards the REPORT version and update and delete use fresh item validators" do
    id, report_version, calendar = @agent.reload.caldav.items(LIST, "events",
      from: Time.iso8601(RANGE.fetch("from")), to: Time.iso8601(RANGE.fetch("to"))).sole
    assert_equal "", report_version, "no validator leaves the REPORT parser"
    assert_equal [ "tool-event", "Original synthetic item" ], [ id, calendar.events.sole.summary.to_s ]

    found = run_call("find", Tool::CalendarFind, RANGE.merge("kind" => "events", "list" => LIST)).fetch(:events).sole
    assert_equal [ LIST, id, "Original synthetic item" ], found.values_at(:list, :id, :title)
    refute found.key?(:etag)
    report_tag = trace.last.fetch("report_etags").sole
    assert_match STRONG_ETAG, report_tag

    # Simulate a second CalDAV client changing a field after the find.
    before = fixture_request(Net::HTTP::Get, ITEM)
    assert_equal report_tag, before["ETag"]
    competing = Icalendar::Calendar.parse(before.body).sole
    competing.events.sole.description = "Competing client's note"
    assert_equal "204", fixture_request(Net::HTTP::Put, ITEM, competing.to_ical, if_match: report_tag).code
    fresh = fixture_request(Net::HTTP::Get, ITEM)["ETag"]
    assert_match STRONG_ETAG, fresh
    refute_equal report_tag, fresh

    saved = run_call("save", Tool::CalendarSaveEvent, "list" => found[:list], "id" => found[:id], "title" => "Synthetic tool edit").fetch(:saved)
    assert_equal [ id, "Synthetic tool edit", "Competing client's note" ], saved.values_at(:id, :title, :notes)
    stored = fixture_request(Net::HTTP::Get, ITEM)
    assert_equal "200", stored.code
    event = Icalendar::Calendar.parse(stored.body).sole.events.sole
    assert_equal [ "tool-event", "Synthetic tool edit", "Competing client's note", "1" ],
      [ event.uid, event.summary, event.description, event.sequence ].map(&:to_s)
    updated = stored["ETag"]
    assert_match STRONG_ETAG, updated
    assert_equal 3, [ report_tag, fresh, updated ].uniq.size

    assert_equal({ deleted: id, list: LIST }, run_call("delete", Tool::CalendarDelete, "list" => found[:list], "id" => found[:id]))
    assert_equal "404", fixture_request(Net::HTTP::Get, ITEM).code

    requests = trace.select { it.fetch("actor") == "client" }
    assert_equal [ [ "REPORT", COLLECTION, 207 ], [ "REPORT", COLLECTION, 207 ],
      [ "GET", ITEM, 200 ], [ "GET", ITEM, 200 ], [ "PUT", ITEM, 204 ],
      [ "GET", ITEM, 200 ], [ "GET", ITEM, 200 ], [ "DELETE", ITEM, 200 ] ],
      requests.map { it.values_at("method", "path", "status") }
    _, _, edit_read, edit_recheck, put, delete_read, delete_recheck, delete = requests
    assert_equal [ fresh, fresh, updated, updated ], [ edit_read, edit_recheck, delete_read, delete_recheck ].map { it.fetch("etag") }
    assert_equal [ [ fresh ], [ updated ] ], [ put, delete ].map { it.fetch("if_match") }
    assert_equal [ [], [] ], [ put, delete ].map { it.fetch("if_none_match") }
  end

  private
    def fixture_request(kind, path, body = nil, if_match: nil)
      request = kind.new(path, { "X-Fixture-Actor" => "proof" })
      if body
        request["Content-Type"] = "text/calendar"
        request.body = body
      end
      request["If-Match"] = if_match if if_match
      Net::HTTP.start(@edge.host, @edge.port, nil, use_ssl: true, open_timeout: 3, read_timeout: 8) { it.request(request) }
    end

    def trace = JSON.parse(fixture_request(Net::HTTP::Get, "/trace").body)

    def run_call(call_id, tool, arguments)
      name = tool.tool_name
      payload = invocation_payload(@conversation, tool: name, arguments: arguments, call_id: call_id)
      receive = -> { Invocation.receive(@conversation, task_id: payload[:taskId], call_id: call_id, tool: name,
        arguments: arguments, digest: payload[:digest]).deep_symbolize_keys }
      receive.call
      perform_enqueued_jobs(only: InvocationCallJob)
      outcome = receive.call
      result = outcome.fetch(:result) { flunk "#{name} did not return a result: #{outcome.inspect}" }
      refute result.key?(:error), "#{name} refused: #{result[:error]}"
      result
    end
end
