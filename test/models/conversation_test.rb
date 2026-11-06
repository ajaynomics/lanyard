require "test_helper"
require_relative "../test_helpers/agent_test_helper"

class ConversationTest < ActiveSupport::TestCase
  include AgentTestHelper
  include ActionCable::TestHelper

  setup do
    install_sidecar_settings
    @bot = create_user.bots.sole
    @conversation = create_conversation(@bot)
    @entries = "#{SIDECAR}/v1/conversations/12/entries"
    @scope = { actorId: @bot.user_id.to_s, workspaceId: @bot.id.to_s }
  end
  teardown { remove_sidecar_settings }

  test "sync pulls every page after the cursor, records each entry once, and keeps out system entries" do
    stub_request(:get, @entries).with(query: @scope.merge(limit: "200"))
      .to_return(body: page([ entry(1, "system", ""), entry(2, "user", "Hello") ], cursor: 2, more: true).to_json)
    stub_request(:get, @entries).with(query: @scope.merge(after: "2", limit: "200"))
      .to_return(body: page([ entry(3, "assistant", "Hi there", toolCalls: [ { id: "call_1", name: "current_time" } ]) ], cursor: 3).to_json)
    stub_request(:get, @entries).with(query: @scope.merge(after: "3", limit: "200")).to_return(body: page([], cursor: 3).to_json)

    @conversation.sync!
    @conversation.sync!

    assert_equal 3, @conversation.reload.last_entry_id
    assert_equal %w[ user assistant ], @conversation.messages.shown.pluck(:role)
    assert_equal [ { "id" => "call_1", "name" => "current_time" } ], @conversation.messages.find_by!(role: "assistant").tool_calls
  end

  test "resync rebuilds the copy from nothing" do
    @conversation.messages.create!(entry_key: "9", entry_id: 9, role: "user", content: "stale")
    @conversation.update!(last_entry_id: 9)
    stub_request(:get, @entries).with(query: @scope.merge(limit: "200")).to_return(body: page([ entry(1, "user", "fresh") ], cursor: 1).to_json)

    @conversation.resync!

    assert_equal [ "fresh" ], @conversation.messages.pluck(:content)
  end

  test "a new message is appended to the page as it arrives; a system entry is not shown" do
    streams = capture_turbo_stream_broadcasts(@conversation) do
      @conversation.messages.create!(entry_key: "1", entry_id: 1, role: "system", content: "")
      @conversation.messages.create!(entry_key: "2", entry_id: 2, role: "user", content: "Hello")
    end

    assert_equal [ "append" ], streams.map { it["action"] }
    assert_includes streams.sole.to_html, "Hello"
  end

  test "a frame replaces the live tail and moves the status; the last frame clears it after the reply is on the page" do
    streams = capture_turbo_stream_broadcasts(@conversation) { @conversation.receive_frame(seq: 5, busy: true, tail: "Half a rep", failure: nil) }
    assert_equal "running", @conversation.status
    live = streams.find { it["target"] == "live_conversation_#{@conversation.id}" }
    assert_includes live.to_html, "Half a rep"
    assert_includes live.to_html, 'data-seq="5"'

    sync = stub_request(:get, @entries).with(query: @scope.merge(limit: "200")).to_return(body: page([ entry(1, "assistant", "Half a reply.") ], cursor: 1).to_json)
    @conversation.receive_frame(seq: 6, busy: false, tail: "Half a reply.", failure: nil)
    assert_requested sync
    assert_equal "idle", @conversation.status
    assert_equal [ "Half a reply." ], @conversation.messages.pluck(:content)
  end

  test "a run that ended without an answer says why" do
    stub_request(:get, @entries).with(query: @scope.merge(limit: "200")).to_return(body: page([], cursor: nil).to_json)
    @conversation.receive_frame(seq: 1, busy: false, tail: "", failure: "model_error")

    assert_equal "error", @conversation.status
    assert_equal "model_error", @conversation.failure
  end

  private
    def entry(id, role, content, **extra) = { id: id.to_s, entryId: id, role: role, content: content, **extra }
    def page(entries, cursor:, more: false) = { entries: entries, cursor: cursor, more: more }
end
