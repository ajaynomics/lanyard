require "test_helper"

class Agent::ReportingConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "two concurrent moves cannot commit opposite reporting lines" do
    owner = User.create!(oidc_sub: "reporting-concurrency", email: "trees@example.com", name: "Trees")
    workspace = owner.personal_workspace
    aster, pip = %w[ Aster Pip ].map { owner.start_agent(it, workspace: workspace) }
    workspace.agents.load
    ready, start = Queue.new, Queue.new

    results = [ [ aster.id, pip.id ], [ pip.id, aster.id ] ].map do |agent_id, manager_id|
      Thread.new do
        Agent.with_connection do
          agent = workspace.agents.find(agent_id)
          ready << true
          start.pop
          [ agent.update(parent_id: manager_id), agent.errors.full_messages ]
        end
      end
    end

    2.times { ready.pop }
    2.times { start << true }
    assert_equal [ false, true ], results.map(&:value).map(&:first).sort_by(&:to_s)
    assert_match(/cannot report to itself or its reports/, results.map(&:value).find { |success, _| !success }.last.sole)
    assert_equal 1, workspace.agents.where.not(parent_id: nil).count
  ensure
    workspace&.agents&.destroy_all
    workspace&.destroy!
    owner&.destroy!
  end
end
