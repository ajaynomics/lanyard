require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# When an agent's outside mail may go (Agent::SendingHours): open from its
# start until its end, each day in its time zone, an end before the start
# running past midnight; otherwise held until the next start, kept on the
# clock across a daylight-saving change.
class AgentSendingHoursTest < ActiveSupport::TestCase
  include AgentTestHelper

  setup { @agent = create_user(name: "Alice").agents.sole }

  def at(*parts, zone: "America/Toronto") = Time.find_zone(zone).local(*parts)

  test "unset, it is never held" do
    assert_not @agent.sending_hours?
    assert_nil @agent.held_until(at(2026, 11, 16, 3, 0))
  end

  test "daytime hours: open from the start up to the end, held until the next start otherwise" do
    @agent.update!(send_from: "08:00", send_until: "19:00", send_time_zone: "America/Toronto")
    assert_nil @agent.held_until(at(2026, 11, 16, 8, 0))
    assert_nil @agent.held_until(at(2026, 11, 16, 18, 59))
    assert_equal at(2026, 11, 16, 8, 0), @agent.held_until(at(2026, 11, 16, 1, 57))
    assert_equal at(2026, 11, 17, 8, 0), @agent.held_until(at(2026, 11, 16, 19, 0))
    assert_equal at(2026, 11, 17, 8, 0), @agent.held_until(at(2026, 11, 16, 22, 22))
    assert_equal at(2026, 11, 17, 8, 0), @agent.held_until(at(2026, 11, 16, 22, 22).utc), "whatever zone the clock is read in"
    assert_equal "08:00 to 19:00, America/Toronto", @agent.sending_hours_label
  end

  test "hours past midnight: open late and early, held through the middle of the day" do
    @agent.update!(send_from: "22:00", send_until: "06:00", send_time_zone: "Europe/London")
    assert_nil @agent.held_until(at(2026, 11, 16, 23, 30, zone: "Europe/London"))
    assert_nil @agent.held_until(at(2026, 11, 17, 5, 59, zone: "Europe/London"))
    assert_equal at(2026, 11, 17, 22, 0, zone: "Europe/London"), @agent.held_until(at(2026, 11, 17, 6, 0, zone: "Europe/London"))
  end

  test "across a daylight-saving change the start stays at its local time" do
    @agent.update!(send_from: "08:00", send_until: "19:00", send_time_zone: "America/Toronto")
    held = @agent.held_until(at(2026, 10, 31, 19, 30)) # clocks go back at 02:00 on Sun 1 Nov
    assert_equal at(2026, 11, 1, 8, 0), held
    assert_equal 8, held.in_time_zone("America/Toronto").hour
  end

  test "all three or none, a real time zone, times as HH:MM, and a start that is not its end" do
    @agent.assign_attributes(send_from: "08:00", send_until: nil, send_time_zone: nil)
    assert_not @agent.valid?
    assert_includes @agent.errors.full_messages.to_sentence, "Sending hours need a start, an end and a time zone"
    @agent.assign_attributes(send_from: "8:00", send_until: "19:00", send_time_zone: "America/Toronto")
    assert_not @agent.valid?
    @agent.assign_attributes(send_from: "08:00", send_until: "19:00", send_time_zone: "Mars/Olympus")
    assert_not @agent.valid?
    @agent.assign_attributes(send_from: "08:00", send_until: "08:00", send_time_zone: "America/Toronto")
    assert_not @agent.valid?
    @agent.assign_attributes(send_from: " 08:00 ", send_until: "19:00", send_time_zone: "America/Toronto")
    assert @agent.valid?, @agent.errors.full_messages.to_sentence
    assert_equal "08:00", @agent.send_from
  end
end
