require "test_helper"
require_relative "../test_helpers/agent_test_helper"

class PilotBudgetConcurrencyTest < ActiveSupport::TestCase
  include AgentTestHelper
  self.use_transactional_tests = false

  test "two connections cannot both reserve the same headroom" do
    user = create_user(name: "Pilot Budget Race")
    agent = user.start_agent("Pilot")
    budget = agent.pilot_budget(:computer)
    ready = Queue.new
    start = Queue.new
    attempts = %w[ first second ].map do |key|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          row = agent.pilot_budgets.find(budget.id)
          ready << true
          start.pop
          row.reserve(key, 3_000)
        end
      end
    end
    attempts.length.times { ready.pop }
    attempts.length.times { start << true }

    assert_equal 1, attempts.filter_map(&:value).size
    assert_equal [ 0, 3_000, 2_000 ], budget.reload.totals
    assert_equal 1, budget.reservations.count
  ensure
    agent&.destroy!
    user&.destroy!
  end
end
