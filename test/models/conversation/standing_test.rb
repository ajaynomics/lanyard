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

  test "each standing a row shows: needs you, error, unread, working, checking, idle, stopped" do
    stopped, idle, working, unread, error, waiting, unknown = %w[ 21 22 23 24 25 26 27 ].map { create_conversation(@conversation.agent, durable_id: it) }
    stopped.agent.create_computer!(provider: "local", state: "off")
    working.update!(status: "running", current_tool: "bash")
    unread.update!(replied_at: 1.minute.ago, read_at: 2.minutes.ago)
    error.update!(status: "error", failure: "rate_limited")
    waiting.update!(status: "waiting")
    unknown.update!(status: "running", execution_status: "unknown")

    assert_equal %w[ idle stopped working unread error needs_you unknown ],
      [ idle, stopped, working, unread, error, waiting, unknown ].map { it.reload.standing }
    row = ApplicationController.render(partial: "conversations/conversation", locals: { conversation: unknown })
    assert_includes row, "Checking run status"
    assert_not_includes row, "Working"
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
    streams = capture_turbo_stream_broadcasts([ @user.personal_workspace, :conversations ]) { @conversation.update!(status: "running") }
    assert_equal [ [ "replace", row, "morph" ] ], streams.map { [ it["action"], it["target"], it["method"] ] }
    assert_equal "working", streams.sole.at("template .conversation-row")["data-standing"]

    stream = capture_turbo_stream_broadcasts([ @user.personal_workspace, :conversations ]) { @conversation.update!(current_tool: "bash") }.sole
    assert_includes stream.at("template .conversation-row__preview").text, "Using bash…"
    assert_empty capture_turbo_stream_broadcasts([ @user.personal_workspace, :conversations ]) { @conversation.update!(current_tool: "bash") }
    assert_empty capture_turbo_stream_broadcasts([ @user.personal_workspace, :conversations ]) { @conversation.update!(usage: { "totalTokens" => 5 }) }
  end

  test "creating, archiving or unarchiving a thread invalidates its workspace's tree; archiving takes its row off at once" do
    stream = [ @user.personal_workspace, :conversations ]
    target = "tree_revision_workspace_#{@user.personal_workspace.id}"
    row = "row_conversation_#{@conversation.id}"
    { -> { @user.start_agent("Researcher") } => [ [ "update", target ] ],
      -> { @conversation.archive } => [ [ "remove", row ], [ "update", target ] ],
      -> { @conversation.unarchive } => [ [ "update", target ] ] }.each do |change, expected|
      updates = capture_turbo_stream_broadcasts(stream, &change)
      assert_equal expected, updates.map { [ it["action"], it["target"] ] }
    end

    branch = @conversation.agent.conversations.create!(request_id: "b-1", parent: @conversation, root: @conversation)
    assert_empty capture_turbo_stream_broadcasts([ @user.personal_workspace, :conversations ]) { branch.update!(status: "running") }
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

  test "the row shows decoded text, not Markdown or HTML elements" do
    @conversation.messages.create!(entry_key: "1", entry_id: 1, role: "assistant", content:
      "**Read** [the notes](https://example.com/notes) &amp;ldquo;today&amp;rdquo; &amp;copy; &amp;#x2605; &lt;label&gt; &notanentity;")

    preview = row_html.at_css(".conversation-row__preview")
    assert_equal "Read the notes “today” © ★ <label> &notanentity;", preview.text
    assert_empty preview.element_children
  end

  test "the row normalizes before clipping the preview to 140 characters" do
    prefix = "a" * 134
    @conversation.messages.create!(entry_key: "1", entry_id: 1, role: "assistant", content:
      "**#{prefix}**\n\n&amp;ldquo;Hi&amp;rdquo; then more words")

    assert_equal "#{prefix} “H...", row_words.first
  end

  test "the newest words remain the preview after tool calls and results" do
    calls = [ { "id" => "one", "name" => "bash" }, { "id" => "two", "name" => "read" } ]
    @conversation.messages.create!(entry_key: "1", entry_id: 1, role: "user", content: "Find the notes.")
    @conversation.messages.create!(entry_key: "2", entry_id: 2, role: "assistant", content: "[tool: bash]I found the notes.[tool: read]", tool_calls: calls)
    assert_equal "I found the notes.", row_words.first

    @conversation.messages.create!(entry_key: "3", entry_id: 3, role: "assistant", content: "\n[tool: bash] \t[tool: read]\n", tool_calls: calls)
    @conversation.messages.create!(entry_key: "4", entry_id: 4, role: "toolResult", content: "Private file listing")
    @conversation.messages.create!(entry_key: "5", entry_id: 5, role: "assistant", content: "\n\t")
    assert_equal "I found the notes.", row_words.first
  end

  private
    def row_words
      html = row_html
      [ html.at_css(".conversation-row__preview").text, html.at_css(".conversation-row__marker")["title"] ]
    end

    def row_html
      Nokogiri::HTML.fragment(ApplicationController.render(partial: "conversations/conversation",
        locals: { conversation: @user.conversations.with_preview.includes(agent: :computer).find(@conversation.id) }))
    end
end
