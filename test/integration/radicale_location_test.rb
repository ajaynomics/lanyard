require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/location_alarm_test_helper"

# Location reminders against a real Radicale (docs/calendar.md), which may
# reorder and refold what it stores. Opt in with a throwaway server on this
# machine, whose accounts take any password, patched as an install's must be
# (test/radicale/sitecustomize.py; unpatched, the longitude is lost and this fails):
#
#   docker run --rm -d --name radicale -p 127.0.0.1:5232:5232 -e PYTHONPATH=/config/python \
#     -v "$PWD/test/radicale:/config/python:ro" tomsquest/docker-radicale:3.8.0.0
#   RADICALE_URL=http://127.0.0.1:5232 bin/rails test test/integration/radicale_location_test.rb
#
# Without RADICALE_URL it skips, so bin/ci never needs the server.
class RadicaleLocationTest < ActiveSupport::TestCase
  include AgentTestHelper
  include LocationAlarmTestHelper
  include ActiveJob::TestHelper

  setup do
    skip "set RADICALE_URL to a throwaway Radicale to run this" unless ENV["RADICALE_URL"]
    @previous_url = Rails.application.config.x.caldav[:url]
    Rails.application.config.x.caldav[:url] = ENV["RADICALE_URL"]
    @account = "agent-#{SecureRandom.hex(4)}"
    @agent = create_user(name: "Maya").agents.sole
    @agent.update!(caldav_username: @account, caldav_password: "any-password")
    @conversation = create_conversation(@agent)
    make_task_list
    radicale(Net::HTTP::Put, "tasks/phone-1.ics", phone_reminder, "Content-Type" => "text/calendar; charset=utf-8")
    @sent = []
    @recording = ->(request, _) { @sent << request.body if request.method == :put && request.uri.path.end_with?(".ics") }
    WebMock.after_request(&@recording)
  end

  teardown do
    WebMock::CallbackRegistry.callbacks.reject! { it[:block] == @recording }
    Rails.application.config.x.caldav[:url] = @previous_url if ENV["RADICALE_URL"]
  end

  test "a location alarm comes back from Radicale as it was sent, beside the time alarm, and goes alone" do
    saved = save("c1", "title" => "Post the letter", "due" => "2026-11-20T17:00", "alarm_minutes" => 30, "location" => "Corner Shop")
    stored = radicale(Net::HTTP::Get, "tasks/#{saved[:id]}.ics").body
    assert_equal location_alarm(@sent.last), location_alarm(stored), "the same properties, once unfolded"
    assert_includes location_alarm(stored), LocationAlarmTestHelper::PHONE_PLACE
    assert_equal time_alarm(@sent.last), time_alarm(stored)

    found = run_call("c2", "calendar_find", "kind" => "tasks", "query" => "letter")[:result][:tasks].sole
    assert_equal [ "Corner Shop", "arrive" ], found.values_at(:location, :proximity)

    save("c3", "id" => saved[:id], "location" => "")
    stored = radicale(Net::HTTP::Get, "tasks/#{saved[:id]}.ics").body
    assert_nil location_alarm(stored)
    assert_includes time_alarm(stored), "TRIGGER;RELATED=END:-PT30M"
  end

  test "an unknown place names the saved ones" do
    outcome = run_call("c1", "calendar_save_task", "list" => "tasks", "title" => "Water plants", "location" => "Lighthouse")[:result]
    assert_match "Saved places: Corner Shop.", outcome[:error]
  end

  private
    def make_task_list
      body = <<~XML
        <?xml version="1.0" encoding="utf-8"?>
        <D:mkcol xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><D:set><D:prop>
          <D:resourcetype><D:collection/><C:calendar/></D:resourcetype><D:displayname>Tasks</D:displayname>
          <C:supported-calendar-component-set><C:comp name="VTODO"/></C:supported-calendar-component-set>
        </D:prop></D:set></D:mkcol>
      XML
      mkcol = Class.new(Net::HTTPRequest) { const_set(:METHOD, "MKCOL"); const_set(:REQUEST_HAS_BODY, true); const_set(:RESPONSE_HAS_BODY, true) }
      radicale(mkcol, "tasks/", body, "Content-Type" => "application/xml; charset=utf-8")
    end

    def radicale(kind, path, body = nil, headers = {})
      uri = URI.join(ENV["RADICALE_URL"].delete_suffix("/") + "/", "#{@account}/#{path}")
      request = kind.new(uri, headers).tap { it.basic_auth(@account, "any-password") }
      request.body = body if body
      Net::HTTP.start(uri.host, uri.port) { it.request(request) }.tap { assert it.is_a?(Net::HTTPSuccess), "#{kind::METHOD} #{path}: HTTP #{it.code}" }
    end

    def save(call_id, arguments) = run_call(call_id, "calendar_save_task", { "list" => "tasks" }.merge(arguments))[:result].fetch(:saved)

    def run_call(call_id, tool, arguments)
      payload = invocation_payload(@conversation, tool: tool, arguments: arguments, call_id: call_id)
      receive = -> { Invocation.receive(@conversation, task_id: payload[:taskId], call_id: call_id, tool: tool, arguments: arguments, digest: payload[:digest]).deep_symbolize_keys }
      receive.()
      perform_enqueued_jobs(only: InvocationCallJob)
      receive.()
    end
end
