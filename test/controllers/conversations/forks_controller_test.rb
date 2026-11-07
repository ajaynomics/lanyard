require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

class Conversations::ForksControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: test reads the person it signed in
    @conversation = create_conversation(@agent)
    @agent.update!(name: "Plan a trip")
    @question = @conversation.messages.create!(entry_key: "4", entry_id: 4, role: "user", content: "Where should I go?")
    @answer = @conversation.messages.create!(entry_key: "5", entry_id: 5, role: "assistant", content: "Lisbon.")
    @again = @conversation.messages.create!(entry_key: "8", entry_id: 8, role: "user", content: "Somewhere warmer?")
  end
  teardown { remove_sidecar_settings }

  test "branch from a reply: the fork keeps the reply, is repeatable by request id, and opens titled as a branch" do
    fork = stub_request(:post, "#{SIDECAR}/v1/conversations/12/forks")
      .with(body: { requestId: "b-1", at: 5, actorId: @agent.user_id.to_s, workspaceId: @agent.id.to_s })
      .to_return(status: 201, body: { id: 40 }.to_json)

    2.times { post conversation_forks_path(@conversation), params: { message_id: @answer.id, request_id: "b-1" } }

    assert_requested fork, times: 2
    branch = @conversation.branches.sole
    assert_redirected_to conversation_path(branch)
    assert_equal [ "40", 5, "Plan a trip (branch)", @agent ], [ branch.durable_id, branch.forked_at_entry_id, branch.title, branch.agent ]
  end

  test "edit: the fork stops just before the person's message, and the branch opens with their words in the box" do
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/forks").with(body: hash_including(at: 5)).to_return(status: 201, body: { id: 41 }.to_json)

    post conversation_forks_path(@conversation), params: { message_id: @again.id, request_id: "e-1" }

    branch = @conversation.branches.sole
    assert_redirected_to conversation_path(branch, draft: @again.id)
    stub_request(:get, "#{SIDECAR}/v1/conversations/41/entries").with(query: hash_including({}))
      .to_return(body: { entries: [ { id: "4", entryId: 4, role: "user", content: "Where should I go?" },
        { id: "5", entryId: 5, role: "assistant", content: "Lisbon." } ], cursor: 5, more: false }.to_json)
    stub_request(:get, "#{SIDECAR}/v1/conversations/41").with(query: hash_including({})).to_return(body: { status: "idle" }.to_json)
    follow_redirect!
    assert_select "#composer textarea", text: "Somewhere warmer?"
    assert_select ".chat__branch a[href=?]", conversation_path(@conversation), text: "Plan a trip"
    assert_select ".chat__branch", text: /working folder/, count: 0
    # The copied history is the branch's own copy, under the parent's entry keys.
    assert_equal %w[ 4 5 ], branch.messages.order(:entry_id).pluck(:entry_key)
  end

  test "editing the first message starts an empty branch" do
    create = stub_request(:post, "#{SIDECAR}/v1/conversations").with(body: hash_including(requestId: "e-2")).to_return(status: 201, body: { id: 42 }.to_json)

    post conversation_forks_path(@conversation), params: { message_id: @question.id, request_id: "e-2" }

    assert_requested create
    assert_nil @conversation.branches.sole.forked_at_entry_id
  end

  test "a reply that is waiting for its tools cannot be branched from; another person's conversation is not found" do
    calling = @conversation.messages.create!(entry_key: "6", entry_id: 6, role: "assistant", content: "",
      tool_calls: [ { "id" => "c", "name" => "current_time" } ])
    post conversation_forks_path(@conversation), params: { message_id: calling.id, request_id: "b-2" }
    assert_response :bad_request

    mallory = create_user(name: "Mallory")
    theirs = create_conversation(mallory.agents.sole, durable_id: "99")
    post conversation_forks_path(theirs), params: { message_id: @answer.id, request_id: "b-3" }
    assert_response :not_found
  end

  test "a branch says it has its own computer when the agent has one" do
    @agent.create_computer!(provider: "local", state: "on")
    branch = @agent.conversations.create!(user: @agent.user, request_id: "b-4", durable_id: "43", parent: @conversation)
    stub_request(:get, "#{SIDECAR}/v1/conversations/43/entries").with(query: hash_including({})).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
    stub_request(:get, "#{SIDECAR}/v1/conversations/43").with(query: hash_including({})).to_return(body: { status: "idle" }.to_json)

    get conversation_path(branch)

    assert_select ".chat__branch", text: /its own computer, which starts empty/
  end
end
