require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# Summarising earlier messages (docs/design/PARITY.md §15): the summary in
# place, the context meter, and what frames say while one is made.
class ConversationCompactionTest < ActiveSupport::TestCase
  include AgentTestHelper
  include ActionCable::TestHelper

  setup do
    install_sidecar_settings
    @agent = create_user.agents.sole
    @conversation = create_conversation(@agent)
    @scope = { actorId: @agent.user_id.to_s, workspaceId: @agent.id.to_s }
  end
  teardown { remove_sidecar_settings }

  test "a summary shows closed, titled, with its own words and not the frame the model reads it in" do
    summary = @conversation.messages.create!(entry_key: "9", entry_id: 9, role: "summary",
      content: "The conversation history before this point was compacted into the following summary:\n\n<summary>\nThey planned **Lisbon**.\n</summary>")

    html = Nokogiri::HTML.fragment(ApplicationController.render(partial: "messages/message", locals: { message: summary }))

    details = html.at_css("details#message_#{summary.id}")
    assert details
    assert_nil details["open"]
    assert_equal "9", details["data-entry-id"]
    assert_equal "Earlier messages summarised", details.at_css("summary").text.strip
    assert_equal "Lisbon", details.at_css("strong").text
    assert_not_includes html.text, "compacted into the following summary"
  end

  test "the context meter measures the newest reply against the model's size and where it summarises, and waits after a summary" do
    stub_models(compact_at: 262_144)
    @conversation.messages.create!(entry_key: "1", entry_id: 1, role: "assistant", content: "Hi", usage: { "totalTokens" => 51_000 })
    @conversation.messages.create!(entry_key: "2", entry_id: 2, role: "assistant", content: "More", usage: { "totalTokens" => 84_321 })
    @conversation.messages.create!(entry_key: "3", entry_id: 3, role: "assistant", content: "", usage: { "totalTokens" => 0 })

    assert_includes usage_html, "Context 8%: 84k of 1M, summarised at 262k"

    @conversation.messages.create!(entry_key: "4", entry_id: 4, role: "summary", content: "<summary>\nx\n</summary>")
    assert_includes usage_html, "Summarised; measured after the next reply"

    @conversation.messages.create!(entry_key: "5", entry_id: 5, role: "assistant", content: "After", usage: { "totalTokens" => 12_400 })
    assert_includes usage_html, "Context 1%: 12k of 1M, summarised at 262k"
  end

  test "no meter before a reply, or when the sidecar can't say where it summarises" do
    stub_models(compact_at: 262_144)
    assert_not_includes usage_html, "summarised at"

    stub_request(:get, "#{SIDECAR}/v1/models").to_return(status: 503, body: { error: "not_ready" }.to_json)
    @conversation.messages.create!(entry_key: "1", entry_id: 1, role: "assistant", content: "Hi", usage: { "totalTokens" => 900 })
    assert_not_includes usage_html, "before summarising"
  end

  test "a frame says a summary is being made, then that it failed; a page load asks the sidecar" do
    streams = capture_turbo_stream_broadcasts(@conversation) do
      @conversation.receive_frame(seq: 1, busy: true, tail: "", failure: nil, compaction: { "trigger" => "threshold" })
    end
    assert_includes live(streams), "Summarising earlier messages…"
    assert_not_includes live(streams), "Working…"

    stub_request(:get, "#{SIDECAR}/v1/conversations/12/entries").with(query: hash_including({}))
      .to_return(body: { entries: [], cursor: nil, more: false }.to_json)
    streams = capture_turbo_stream_broadcasts(@conversation) do
      @conversation.receive_frame(seq: 2, busy: false, tail: "", failure: nil, compaction: nil, compaction_failed: { "trigger" => "manual" })
    end
    assert_includes live(streams), "Couldn't summarise earlier messages. Type /compact to try again."
    assert_equal "idle", @conversation.reload.status

    stub_request(:get, "#{SIDECAR}/v1/conversations/12").with(query: @scope)
      .to_return(body: { status: "idle", compaction: { trigger: "manual" }, compactionFailed: nil }.to_json)
    @conversation.refresh_status!
    assert @conversation.compacting?
    assert_not @conversation.compaction_failed?
  end

  test "the notes file's size shows under the meter, from the last frame or a page load, and says when it was too large" do
    stub_request(:get, "#{SIDECAR}/v1/conversations/12/entries").with(query: hash_including({}))
      .to_return(body: { entries: [], cursor: nil, more: false }.to_json)
    streams = capture_turbo_stream_broadcasts(@conversation) do
      @conversation.receive_frame(seq: 1, busy: false, tail: "", failure: nil, notes_file: { "bytes" => 3_000 }, usage: { "totalTokens" => 5 })
    end
    assert_equal 3_000, @conversation.reload.notes_file_bytes
    assert_includes streams.find { it["target"] == "usage_conversation_#{@conversation.id}" }.to_html, "Notes file: AGENTS.md, 3 KB"

    stub_request(:get, "#{SIDECAR}/v1/conversations/12").with(query: @scope).to_return(body: { status: "idle", notesFile: { bytes: 40_000 } }.to_json)
    @conversation.refresh_status!
    assert_includes usage_html, "Notes file: AGENTS.md, 40 KB, too large to read (up to 32 KB)"

    stub_request(:get, "#{SIDECAR}/v1/conversations/12").with(query: @scope).to_return(body: { status: "idle", notesFile: nil }.to_json)
    @conversation.refresh_status!
    assert_nil @conversation.reload.notes_file_bytes
    assert_not_includes usage_html, "Notes file"
  end

  test "a run that waited for a summary that failed says so in words" do
    assert_equal "couldn't summarise earlier messages. Type /compact to try again.",
      ApplicationController.helpers.failure_text("compaction_failed")
  end

  test "compact sends the request id and the words, and leaves out words that were not given" do
    with_words = stub_request(:post, "#{SIDECAR}/v1/conversations/12/compactions")
      .with(body: @scope.merge(requestId: "c-1", instructions: "Keep the dates")).to_return(status: 202, body: { id: "31" }.to_json)
    without = stub_request(:post, "#{SIDECAR}/v1/conversations/12/compactions")
      .with(body: @scope.merge(requestId: "c-2")).to_return(status: 202, body: { id: "32" }.to_json)

    @conversation.compact(request_id: "c-1", instructions: "Keep the dates")
    @conversation.compact(request_id: "c-2")

    assert_requested with_words
    assert_requested without
  end

  private
    def stub_models(compact_at:)
      stub_request(:get, "#{SIDECAR}/v1/models").to_return(body: { models: [
        { id: @agent.model, name: "Model", thinkingLevels: %w[ medium ], images: true, contextWindow: 1_000_000, compactAt: compact_at }
      ] }.to_json)
    end

    def usage_html = ApplicationController.render(partial: "conversations/usage", locals: { conversation: @conversation })

    def live(streams) = streams.find { it["target"] == "live_conversation_#{@conversation.id}" }.to_html
end
