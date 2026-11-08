require "test_helper"
require_relative "../test_helpers/agent_test_helper"

class ComputerRemovalJobTest < ActiveJob::TestCase
  include AgentTestHelper

  setup { install_sidecar_settings }
  teardown { remove_sidecar_settings }

  test "asks the sidecar to delete each conversation's Sprite, as the deleted agent's owner, and a conversation it never knew is fine" do
    alice = create_user
    removed = %w[ 12 13 ].map do |id|
      stub_request(:delete, "#{SIDECAR}/v1/conversations/#{id}/computer")
        .with(query: { actorId: alice.id.to_s, workspaceId: "41", computer: "avery-test-b41" },
              headers: { "Authorization" => "Bearer #{SIDECAR_TOKEN}" })
        .to_return(**(id == "13" ? { status: 404, body: { error: "not_found" }.to_json } : { status: 200, body: { removed: true }.to_json }))
    end

    ComputerRemovalJob.perform_now(alice, 41, "avery-test-b41", %w[ 12 13 ])

    removed.each { assert_requested it }
  end

  test "tries again later while the sidecar cannot be reached" do
    stub_request(:delete, %r{/v1/conversations/12/computer}).to_return(status: 503, body: { error: "not_ready" }.to_json)

    assert_enqueued_with(job: ComputerRemovalJob) do
      ComputerRemovalJob.perform_now(create_user, 41, "avery-test-b41", %w[ 12 ])
    end
  end
end
