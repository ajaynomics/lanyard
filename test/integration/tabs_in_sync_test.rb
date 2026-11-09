require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# Two tabs, or a phone and a laptop, on one agent's settings: a change in one
# morphs the other (Turbo page refreshes). The page listens to the agent, and
# the agent and each of its parts say when they change.
class TabsInSyncTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include ActiveJob::TestHelper

  setup do
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: test reads the person it signed in
  end

  test "every page of an agent's settings listens to the agent" do
    stream = Turbo::StreamsChannel.signed_stream_name(@agent)
    [ agent_path(@agent), agent_tools_path(@agent), agent_skills_path(@agent), agent_routines_path(@agent), agent_channels_path(@agent) ].each do |page|
      get page
      assert_select "turbo-cable-stream-source[signed-stream-name='#{stream}']", 1, page
    end
  end

  test "the agent and its parts each refresh the agent's pages when they change" do
    assert_turbo_stream_broadcasts(@agent, count: 1) { perform_enqueued_jobs { @agent.update!(instructions: "Be brief.") } }
    assert_turbo_stream_broadcasts(@agent, count: 1) { perform_enqueued_jobs { @agent.skills.create!(name: "trips", description: "Trips", body: "Plan them.") } }
    assert_turbo_stream_broadcasts(@agent, count: 1) { perform_enqueued_jobs { @agent.notes.create!(key: "seats", body: "Likes window seats") } }
    refresh = capture_turbo_stream_broadcasts(@agent) { perform_enqueued_jobs { @agent.update!(instructions: "Be briefer.") } }.sole
    assert_equal "refresh", refresh["action"]
  end
end
