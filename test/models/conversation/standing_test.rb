require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

# Where each agent's thread stands in the list, and that list kept in step,
# one row at a time (Conversation::Standing).
class Conversation::StandingTest < ActiveSupport::TestCase
  include AgentTestHelper

  setup do
    install_sidecar_settings
    @user = create_user
    @conversation = create_conversation(@user.agents.sole)
  end
  teardown { remove_sidecar_settings }

  test "each standing a row shows: needs you, error, unread, working, idle, stopped" do
    stopped, idle, working, unread, error, waiting = %w[ 21 22 23 24 25 26 ].map { create_conversation(@conversation.agent, durable_id: it) }
    stopped.agent.create_computer!(provider: "local", state: "off")
    working.update!(status: "running", current_tool: "bash")
    unread.update!(replied_at: 1.minute.ago, read_at: 2.minutes.ago)
    error.update!(status: "error", failure: "rate_limited")
    waiting.update!(status: "waiting")

    assert_equal %w[ idle stopped working unread error needs_you ], [ idle, stopped, working, unread, error, waiting ].map { it.reload.standing }
  end

  test "only news for the person moves a row up: a card that starts waiting on them, or a reply to them" do
    other = create_conversation(@conversation.agent, durable_id: "21")
    travel_to(1.hour.from_now) { other.update!(listed_at: Time.current) }
    news = -> { @user.conversations.threads.by_news.to_a }
    assert_equal [ other, @conversation ], news.call

    travel_to(2.hours.from_now) do
      @conversation.update!(status: "running", current_tool: "bash")
      @conversation.update!(status: "error", failure: "rate_limited")
      @conversation.messages.create!(entry_key: "1", entry_id: 1, role: "user", content: "Try again")
      @conversation.messages.create!(entry_key: "2", entry_id: 2, role: "assistant", content: "Calling…", tool_calls: [ { "id" => "c", "name" => "bash" } ])
      @conversation.read!
      assert_equal [ other, @conversation ], news.call, "work, errors, the person's words, tool calls and reads stay in place"

      @conversation.update!(status: "waiting")
      assert_equal [ @conversation, other ], news.call, "a card waiting on the person"
    end

    travel_to(3.hours.from_now) do
      @conversation.update!(status: "running")
      other.messages.create!(entry_key: "1", entry_id: 1, role: "assistant", content: "Done.")
      assert_equal [ other, @conversation ], news.call, "answering the card is not news; a reply is"
    end
  end

  test "a reply makes the thread unread until it is opened; the person's own words don't" do
    @conversation.messages.create!(entry_key: "1", entry_id: 1, role: "user", content: "Book Lisbon")
    assert_not @conversation.reload.unread?
    @conversation.messages.create!(entry_key: "2", entry_id: 2, role: "assistant", content: "Calling…", tool_calls: [ { "id" => "c", "name" => "book" } ])
    assert_not @conversation.reload.unread?, "a reply that calls a tool is not an answer yet"
    @conversation.messages.create!(entry_key: "3", entry_id: 3, role: "assistant", content: "Booked.")
    assert @conversation.reload.unread?

    @conversation.read!
    assert_not @conversation.reload.unread?
  end

  test "a change the row shows is broadcast as that row alone; anything else, or the same tool again, is not" do
    row = ActionView::RecordIdentifier.dom_id(@conversation, :row)
    streams = capture_turbo_stream_broadcasts([ @user, :conversations ]) { @conversation.update!(status: "running") }
    assert_equal [ [ "replace", row, "morph" ] ], streams.map { [ it["action"], it["target"], it["method"] ] }
    assert_equal "working", streams.sole.at("template li")["data-standing"]

    stream = capture_turbo_stream_broadcasts([ @user, :conversations ]) { @conversation.update!(current_tool: "bash") }.sole
    assert_includes stream.at("template .conversation-row__preview").text, "Using bash…"
    assert_empty capture_turbo_stream_broadcasts([ @user, :conversations ]) { @conversation.update!(current_tool: "bash") }
    assert_empty capture_turbo_stream_broadcasts([ @user, :conversations ]) { @conversation.update!(usage: { "totalTokens" => 5 }) }
  end

  test "a new agent joins the list, an archived one leaves, and unarchived it comes back; a branch is never listed" do
    added = capture_turbo_stream_broadcasts([ @user, :conversations ]) { @user.start_agent("Researcher") }
    assert_equal [ [ "prepend", "agents_list" ] ], added.map { [ it["action"], it["target"] ] }
    assert_includes added.sole.at("template").text, "Researcher"

    row = ActionView::RecordIdentifier.dom_id(@conversation, :row)
    assert_equal [ [ "remove", row ] ], capture_turbo_stream_broadcasts([ @user, :conversations ]) { @conversation.archive }.map { [ it["action"], it["target"] ] }
    assert_equal [ [ "prepend", "agents_list" ] ], capture_turbo_stream_broadcasts([ @user, :conversations ]) { @conversation.unarchive }.map { [ it["action"], it["target"] ] }

    branch = @conversation.agent.conversations.create!(user: @user, request_id: "b-1", parent: @conversation, root: @conversation)
    assert_empty capture_turbo_stream_broadcasts([ @user, :conversations ]) { branch.update!(status: "running") }
  end

  test "the row says what the agent needs, why it stopped, and what it is doing" do
    payload = invocation_payload(@conversation, tool: "ask_person", arguments: { "question" => "Tea or coffee?", "options" => %w[ Tea Coffee ] }, call_id: "c1")
    Invocation.receive(@conversation, task_id: 7, call_id: "c1", tool: "ask_person", arguments: payload[:arguments], digest: payload[:digest])
    @conversation.update!(status: "waiting")
    assert_equal [ "Tea or coffee?", "Needs you: Tea or coffee?" ], row_words

    @conversation.update!(status: "error", failure: "rate_limited")
    assert_match(/\ACouldn't finish: /, row_words.first)
    assert_match(/\AStopped by an error: /, row_words.last)
  end

  private
    def row_words
      html = Nokogiri::HTML.fragment(ApplicationController.render(partial: "conversations/conversation",
        locals: { conversation: @user.conversations.with_preview.includes(agent: :computer).find(@conversation.id) }))
      [ html.at_css(".conversation-row__preview").text, html.at_css(".conversation-row__marker")["title"] ]
    end
end
