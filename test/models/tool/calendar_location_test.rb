require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/caldav_test_helper"
require_relative "../../test_helpers/location_alarm_test_helper"

class Tool::CalendarLocationTest < ActiveSupport::TestCase
  include AgentTestHelper
  include CaldavTestHelper
  include LocationAlarmTestHelper
  include ActiveJob::TestHelper

  setup do
    @items = install_caldav
    @agent = create_user(name: "Maya").agents.sole
    @agent.update!(time_zone: "Eastern Time (US & Canada)", caldav_username: "agent-1", caldav_password: "app-password")
    @conversation = create_conversation(@agent)
    caldav_put "tasks", "phone-1", phone_reminder
  end

  teardown { remove_caldav }

  test "a task set to fire on arriving at a saved place gets the phone's own location alarm" do
    saved = save("c1", "title" => "Post the letter", "location" => "corner shop")
    assert_equal [ "Corner Shop", "arrive" ], saved.values_at(:location, :proximity)

    alarm = location_alarm(stored(saved))
    assert_includes alarm, LocationAlarmTestHelper::PHONE_PLACE, "the place as the phone wrote it, parameters and all"
    assert_includes alarm, "ACTION:DISPLAY"
    assert_includes alarm, "X-APPLE-PROXIMITY:ARRIVE"
    assert_includes alarm, "TRIGGER;VALUE=DATE-TIME:19760401T005545Z"
    uid = alarm.find { it.start_with?("UID:") }.delete_prefix("UID:")
    assert_includes alarm, "X-WR-ALARMUID:#{uid}"
    assert_equal 7, alarm.size
  end

  test "leaving is DEPART" do
    saved = save("c1", "title" => "Lock up", "location" => "Corner Shop", "proximity" => "leave")
    assert_equal "leave", saved[:proximity]
    assert_includes location_alarm(stored(saved)), "X-APPLE-PROXIMITY:DEPART"
  end

  test "a time alarm and a location alarm live side by side, and taking the place away keeps the time" do
    saved = save("c1", "title" => "Pick up the parcel", "due" => "2026-11-20T17:00", "alarm_minutes" => 30, "location" => "Corner Shop")
    assert_equal 2, unfolded_alarms(stored(saved)).size
    assert_includes time_alarm(stored(saved)), "TRIGGER;RELATED=END:-PT30M"

    save("c2", "id" => saved[:id], "alarm_minutes" => 10)
    assert_includes time_alarm(stored(saved)), "TRIGGER;RELATED=END:-PT10M"
    assert location_alarm(stored(saved)), "a new time alarm leaves the place alone"

    save("c3", "id" => saved[:id], "proximity" => "leave", "location" => "Corner Shop")
    assert_equal 2, unfolded_alarms(stored(saved)).size, "a new place replaces the old one, never adds a second"
    assert_includes location_alarm(stored(saved)), "X-APPLE-PROXIMITY:DEPART"
    save("c4", "id" => saved[:id], "location" => "corner shop")
    assert_includes location_alarm(stored(saved)), "X-APPLE-PROXIMITY:DEPART", "naming the place again keeps when it fires"

    cleared = save("c5", "id" => saved[:id], "location" => "")
    assert_nil cleared[:location]
    assert_nil location_alarm(stored(saved))
    assert_includes time_alarm(stored(saved)), "TRIGGER;RELATED=END:-PT10M"
  end

  test "a place nobody saved is refused, naming the saved ones, and nothing is written" do
    outcome = run_call("c1", "calendar_save_task", "list" => "tasks", "title" => "Water plants", "location" => "Lighthouse")[:result]
    assert_equal "No saved place is called Lighthouse. Saved places: Corner Shop. " \
      "A place is saved by setting a reminder to fire there on a phone; none is looked up.", outcome[:error]
    assert_equal [ "phone-1" ], @items["tasks"].keys
  end

  test "a proximity needs a place" do
    outcome = run_call("c1", "calendar_save_task", "list" => "tasks", "title" => "Water plants", "proximity" => "leave")[:result]
    assert_equal "A proximity needs a location: the saved place to arrive at or leave.", outcome[:error]
  end

  test "calendar_find shows each task's place and whether it fires on arriving or leaving" do
    caldav_put "tasks", "phone-2", phone_reminder(uid: "phone-2", title: "Return the book", proximity: "DEPART")
    found = run_call("c1", "calendar_find", "kind" => "tasks")[:result][:tasks]
    assert_equal [ [ "Buy stamps", "Corner Shop", "arrive" ], [ "Return the book", "Corner Shop", "leave" ] ],
      found.map { it.values_at(:title, :location, :proximity) }.sort
    assert_equal [ "Buy stamps", "Return the book" ], run_call("c2", "calendar_find", "kind" => "tasks", "query" => "corner")[:result][:tasks].pluck(:title).sort
    assert found.none? { it.key?(:alarms) }, "a reminder for a place is shown as its place, not as an alarm at its long-past trigger"

    save("c3", "title" => "Pick up the parcel", "due" => "2026-11-20T17:00", "alarm_minutes" => 30, "location" => "Corner Shop")
    parcel = run_call("c4", "calendar_find", "kind" => "tasks", "query" => "parcel")[:result][:tasks].sole
    assert_equal [ [ { minutes: 30, before: "due", action: "display" } ], "Corner Shop" ], parcel.values_at(:alarms, :location)
  end

  private
    def save(call_id, arguments) = run_call(call_id, "calendar_save_task", { "list" => "tasks" }.merge(arguments))[:result].fetch(:saved)
    def stored(saved) = @items["tasks"].fetch(saved[:id]).last

    def run_call(call_id, tool, arguments)
      payload = invocation_payload(@conversation, tool: tool, arguments: arguments, call_id: call_id)
      receive = -> { Invocation.receive(@conversation, task_id: payload[:taskId], call_id: call_id, tool: tool, arguments: arguments, digest: payload[:digest]).deep_symbolize_keys }
      receive.()
      perform_enqueued_jobs(only: InvocationCallJob)
      receive.()
    end
end
