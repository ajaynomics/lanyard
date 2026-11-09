require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

class Conversations::QueuedMessagesControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: test reads the person it signed in
    @conversation = create_conversation(@agent)
    @scope = { actorId: @agent.user_id.to_s, workspaceId: @agent.id.to_s }
    @snapshot = "#{SIDECAR}/v1/conversations/12"
    @item = "#{SIDECAR}/v1/conversations/12/queued/31"
  end
  teardown { remove_sidecar_settings }

  test "the person makes a waiting message a steer, and the list is redrawn from the sidecar's" do
    waiting [ { id: "31", mode: "followUp", text: "Rome, not Paris", pictures: 0 } ]
    change = stub_request(:patch, @item).with(body: @scope.merge(whenBusy: "steer")).to_return(body: { changed: true }.to_json)

    streams = capture_turbo_stream_broadcasts(@conversation) do
      patch conversation_queued_message_path(@conversation, 31), params: { when_busy: "steer" }, as: :turbo_stream
    end

    assert_response :ok
    assert_requested change
    list = streams.find { it["target"] == "queued_conversation_#{@conversation.id}" }
    assert_includes list.to_html, "Rome, not Paris"
  end

  test "withdrawing a message the agent has already read says so, and nothing goes back in the box" do
    waiting [ { id: "31", mode: "steer", text: "Rome, not Paris", pictures: 0 } ]
    stub_request(:delete, @item).with(query: @scope).to_return(body: { withdrawn: false }.to_json)

    delete conversation_queued_message_path(@conversation, 31), as: :turbo_stream

    assert_response :conflict
    assert_includes response.body, "has already read that message"
  end

  test "someone else's mail waiting for the agent is not the person's to change or take back" do
    mail = Conversation.received("Can you call me?", from: "acme/sam, task 9", via: "Concourse mail", answer: "Reply with concourse_reply.")
    waiting [ { id: "31", mode: "followUp", text: mail, pictures: 0 } ]

    delete conversation_queued_message_path(@conversation, 31), as: :turbo_stream
    patch conversation_queued_message_path(@conversation, 31), params: { when_busy: "steer" }, as: :turbo_stream

    assert_response :conflict
    assert_not_requested :any, @item
  end

  test "an unknown mode is refused before the sidecar is asked" do
    patch conversation_queued_message_path(@conversation, 31), params: { when_busy: "reject" }
    assert_response :bad_request
  end

  test "another person's thread is not found" do
    other = create_conversation(create_user(name: "Robin").agents.sole)
    delete conversation_queued_message_path(other, 31)
    assert_response :not_found
  end

  private
    def waiting(items)
      stub_request(:get, @snapshot).with(query: @scope).to_return(body: { id: "12", status: "running", queued: items }.to_json)
    end
end
