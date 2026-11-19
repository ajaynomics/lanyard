require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# A workspace's live lists (its agents, its helpers) are heard only by its
# members. A signed stream name never expires, so the channel asks at each
# subscription, and removing someone closes their open connections, whose
# pages then subscribe afresh and are refused.
class WorkspaceStreamsChannelTest < ActionCable::Channel::TestCase
  include AgentTestHelper

  setup do
    @alice, @bob = create_user(name: "Alice"), create_user(name: "Bob")
    @shared = Workspace.create!(name: "Household")
    @shared.memberships.create!(user: @alice, role: "owner")
    @membership = @shared.memberships.create!(user: @bob, role: "member")
    @stream = Turbo::StreamsChannel.signed_stream_name([ @shared, :conversations ])
  end

  test "a member hears the shared list, which a thread in it updates" do
    stub_connection current_user: @bob
    subscribe signed_stream_name: @stream

    assert subscription.confirmed?
    assert_has_stream Turbo::StreamsChannel.verified_stream_name(@stream)
    agent = @shared.agents.create!(user: @alice, name: "Shared", instructions: "Help.", model: Agent.models.first)
    assert_turbo_stream_broadcasts [ @shared, :conversations ] do
      agent.conversation.broadcast_row
    end
  end

  test "someone outside the workspace is refused its list" do
    stub_connection current_user: @bob
    subscribe signed_stream_name: Turbo::StreamsChannel.signed_stream_name([ @alice.personal_workspace, :conversations ])

    assert subscription.rejected?
  end

  test "a member hears a shared thread; someone outside, nothing of it" do
    agent = @shared.agents.create!(user: @alice, name: "Shared", instructions: "Help.", model: Agent.models.first)
    stub_connection current_user: @bob
    subscribe signed_stream_name: Turbo::StreamsChannel.signed_stream_name(agent.conversation)
    assert subscription.confirmed?

    stub_connection current_user: create_user(name: "Sam")
    subscribe signed_stream_name: Turbo::StreamsChannel.signed_stream_name(agent.conversation)
    assert subscription.rejected?
  end

  test "a removed member's open connections close, and the list refuses them after" do
    assert_broadcasts "action_cable/#{@bob.to_gid_param}", 1 do
      @membership.destroy!
    end

    stub_connection current_user: @bob
    subscribe signed_stream_name: @stream
    assert subscription.rejected?
  end
end
