require "test_helper"

class ConversationsHelperTest < ActionView::TestCase
  test "a row's time is short: now, minutes, hours today, the weekday this week, then the date" do
    now = Time.zone.local(2026, 11, 12, 15, 0)
    assert_equal "now", list_time(now - 20.seconds, now: now)
    assert_equal "now", list_time(now + 5.seconds, now: now), "a clock a little ahead"
    assert_equal "4m", list_time(now - 4.minutes, now: now)
    assert_equal "59m", list_time(now - 59.minutes, now: now)
    assert_equal "2h", list_time(now - 2.hours - 10.minutes, now: now)
    assert_equal "14h", list_time(now - 14.hours, now: now)
    assert_equal "Wed", list_time(now - 1.day, now: now)
    assert_equal "Mon", list_time(Time.zone.local(2026, 11, 9, 9), now: now)
    assert_equal "Nov 5", list_time(Time.zone.local(2026, 11, 5, 9), now: now)
    assert_equal "12/30/25", list_time(Time.zone.local(2025, 12, 30, 9), now: now)
  end

  test "just after midnight, two hours ago is yesterday's weekday, not hours" do
    now = Time.zone.local(2026, 11, 12, 1, 0)
    assert_equal "Wed", list_time(now - 2.hours, now: now)
  end
end
