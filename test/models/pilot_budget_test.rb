require "test_helper"
require_relative "../test_helpers/agent_test_helper"

class PilotBudgetTest < ActiveSupport::TestCase
  include AgentTestHelper

  setup do
    @agent = create_user(name: "Ada").start_agent("Pilot")
    travel_to Time.utc(2026, 11, 22, 12)
    @voice = @agent.pilot_budget(:voice)
    @computer = @agent.pilot_budget(:computer)
  end

  test "voice and computing each reserve against their own fifty dollar ceiling" do
    assert @voice.reserve("v1", 4_900)
    assert @computer.reserve("c1", 5_000)
    assert_nil @voice.reserve("v2", 101)
    assert_nil @computer.reserve("c2", 1)
    assert_equal [ 0, 4_900, 100 ], @voice.reload.totals
    assert_equal [ 0, 5_000, 0 ], @computer.reload.totals
  end

  test "an unknown or noninteger maximum spends nothing and an uncertain settlement keeps its hold" do
    [ nil, "5000", 25.5, -1, 0 ].each { |maximum| assert_nil @voice.reserve("unknown", maximum) }
    assert @voice.reserve("call", 5_000)
    assert_not @voice.settle("call", nil)
    assert_nil @voice.reserve("second", 1)
    assert_equal [ 0, 5_000, 0 ], @voice.reload.totals
    assert @voice.settle("call", 0)
    assert_equal [ 0, 0, 5_000 ], @voice.reload.totals
  end

  test "a duplicate request never yields another authorization" do
    assert @voice.reserve("call", 500)
    assert_nil @voice.reserve("call", 500)
    assert_nil @voice.reserve("call", 100)
    assert @voice.settle("call", 200)
    assert @voice.settle("call", 200)
    assert_not @voice.settle("call", 201)
    assert_nil @voice.reserve("call", 500)
    assert_equal [ 200, 0, 4_800 ], @voice.reload.totals
  end

  test "final charges generate one durable alert for each threshold crossed this month" do
    assert @voice.reserve("first", 2_500)
    assert_empty @voice.alerts
    assert @voice.settle("first", 2_500)
    assert @voice.settle("first", 2_500)
    assert_equal [ 50 ], @voice.alerts.order(:threshold).pluck(:threshold)
    assert @voice.reserve("second", 1_600)
    assert @voice.settle("second", 1_500)
    assert @voice.reserve("third", 100)
    assert @voice.settle("third", 100)
    assert_equal [ 50, 80 ], @voice.alerts.order(:threshold).pluck(:threshold)
    assert_equal "Voice: $41.00 used of $50.00 this month", @voice.brief_line
    assert_empty @computer.alerts
  end

  test "a charge above the reserved maximum blocks further spending and remains visible" do
    assert @voice.reserve("call", 500)
    assert_not @voice.settle("call", 501)
    assert_nil @voice.reserve("second", 1)
    assert_equal [ 501, 0, 0 ], @voice.reload.totals
    assert_predicate @voice, :blocked?
  end

  test "the next UTC month is separate and a stale receipt cannot start another charge" do
    assert @voice.reserve("call", 5_000)
    travel_to Time.utc(2026, 12, 1)
    assert_nil @voice.reserve("late", 1)
    assert_nil @agent.pilot_budget(:voice).reserve("next", 5_000), "do not forget an unresolved hold"
    assert @voice.settle("call", 5_000)
    assert @agent.pilot_budget(:voice).reserve("next", 5_000)
  end

  test "one agent cannot use another agent's reservation ID" do
    other = create_user(name: "Bea").start_agent("Other")
    assert @voice.reserve("call", 700)
    assert_not other.pilot_budget(:voice).settle("call", 0)
    assert_equal [ 0, 700, 4_300 ], @voice.reload.totals
  end
end
