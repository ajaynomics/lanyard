require "test_helper"
require_relative "../../../test_helpers/agent_test_helper"

class Conversations::QueuedMessages::PositionsControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: test reads the person it signed in
    @conversation = create_conversation(@agent)
    @scope = { actorId: @agent.user_id.to_s, workspaceId: @agent.id.to_s }
    @position = "#{SIDECAR}/v1/conversations/12/queued/31/position"
    mail = Conversation.received("Rome?", from: "acme/sam, task 9", via: "Concourse mail", answer: "Reply with concourse_reply.")
    stub_request(:get, "#{SIDECAR}/v1/conversations/12").with(query: @scope)
      .to_return(body: { id: "12", status: "running", queued: [ { id: "30", mode: "followUp", text: "And dinner", pictures: 0 }, { id: "31", mode: "followUp", text: mail, pictures: 0 } ] }.to_json)
  end
  teardown { remove_sidecar_settings }

  test "a waiting message from anyone moves up one place, and the list is redrawn" do
    move = stub_request(:put, @position).with(body: @scope.merge(to: "up")).to_return(body: { moved: true }.to_json)

    streams = capture_turbo_stream_broadcasts(@conversation) do
      patch conversation_queued_message_position_path(@conversation, 31), params: { to: "up" }, as: :turbo_stream
    end

    assert_response :ok
    assert_requested move
    assert streams.any? { it["target"] == "queued_conversation_#{@conversation.id}" }
  end

  test "moving a message the agent has already read says so" do
    stub_request(:put, @position).to_return(body: { moved: false }.to_json)

    patch conversation_queued_message_position_path(@conversation, 31), params: { to: "down" }, as: :turbo_stream

    assert_response :conflict
    assert_includes response.body, "has already read that message"
  end

  test "an unknown place is refused before the sidecar is asked" do
    patch conversation_queued_message_position_path(@conversation, 31), params: { to: "sideways" }
    assert_response :bad_request
    assert_not_requested :put, @position
  end
end
