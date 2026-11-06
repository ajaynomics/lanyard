require "test_helper"
require_relative "../test_helpers/agent_test_helper"

class ConversationTest < ActiveSupport::TestCase
  include AgentTestHelper
  include ActionCable::TestHelper
  include ActiveJob::TestHelper

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

  test "sync keeps what the model thought and the pictures a tool returned, and shows both" do
    jpeg = Base64.strict_encode64("\xFF\xD8\xFF fixture".b)
    stub_request(:get, @entries).with(query: @scope.merge(limit: "200")).to_return(body: page([
      entry(1, "assistant", "Let me look.", thinking: "The person wants a site.", toolCalls: [ { id: "call_v", name: "visit_website" } ]),
      entry(2, "toolResult", "Visited https://example.com/", toolName: "visit_website", toolCallId: "call_v",
        images: [ { mimeType: "image/jpeg", data: jpeg }, { mimeType: "text/html", data: jpeg }, { mimeType: "image/png", data: "not base64!" } ])
    ], cursor: 2).to_json)

    @conversation.sync!

    thought, result = @conversation.messages.order(:entry_id)
    assert_equal "The person wants a site.", thought.thinking
    assert_equal 1, result.images.count
    assert_equal "image/jpeg", result.images.first.content_type
    html = ApplicationController.render(partial: "messages/message", collection: [ thought, result ], as: :message)
    assert_includes html, "Thought process"
    assert_includes html, "The person wants a site."
    assert_match %r{<img[^>]+alt="What visit website saw"}, html
  end

  test "a frame streams the thinking, then the answer" do
    streams = capture_turbo_stream_broadcasts(@conversation) { @conversation.receive_frame(seq: 1, busy: true, tail: "", thinking: "Hmm, **maybe**", failure: nil) }
    live = streams.find { it["target"] == "live_conversation_#{@conversation.id}" }.to_html
    assert_includes live, "Thinking…"
    assert_includes live, "<strong>maybe</strong>"

    streams = capture_turbo_stream_broadcasts(@conversation) { @conversation.receive_frame(seq: 2, busy: true, tail: "The *answer*", thinking: "Hmm", failure: nil) }
    live = streams.find { it["target"] == "live_conversation_#{@conversation.id}" }.to_html
    assert_includes live, "Thought process"
    assert_includes live, "<em>answer</em>"
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

    # The person's first message also takes away the suggestions of an empty conversation.
    assert_equal %w[ append remove ], streams.map { it["action"] }
    assert_includes streams.first.to_html, "Hello"
    assert_equal "empty_conversation_#{@conversation.id}", streams.last["target"]
  end

  test "a reply that failed before its first word leaves no empty bubble" do
    failed = @conversation.messages.create!(entry_key: "1", entry_id: 1, role: "assistant", content: "")
    assert_empty ApplicationController.render(partial: "messages/message", locals: { message: failed }).strip
  end

  test "a sidecar tool's result retires its running line, live and on a reload" do
    @conversation.messages.create!(entry_key: "1", entry_id: 1, role: "assistant", content: "", tool_calls: [ { "id" => "call_b", "name" => "bash" } ])
    streams = capture_turbo_stream_broadcasts(@conversation) do
      @conversation.messages.create!(entry_key: "2", entry_id: 2, role: "toolResult", content: "ok", tool_name: "bash", tool_call_id: "call_b")
    end

    assert_equal %w[ append remove ], streams.map { it["action"] }
    assert_equal Invocation.dom_target("call_b"), streams.last["target"]
    html = ApplicationController.render(partial: "messages/message", locals: { message: @conversation.messages.find_by!(entry_key: "1") })
    assert_not_includes html, "Running bash"
  end

  test "a frame morphs the live tail and moves the status; the last frame puts the reply on the page before it clears the tail" do
    streams = capture_turbo_stream_broadcasts(@conversation) { @conversation.receive_frame(seq: 5, busy: true, tail: "Half a rep", failure: nil) }
    assert_equal "running", @conversation.status
    live = streams.find { it["target"] == "live_conversation_#{@conversation.id}" }
    assert_equal "morph", live["method"]
    assert_includes live.to_html, "Half a rep"
    assert_includes live.to_html, 'data-seq="5"'

    # The last frame pulls the committed reply first: appended with its live copy
    # cleared in the same breath, then the status settles, then the tail clears
    # above the last frame's sequence. No job waits.
    stub_request(:get, @entries).with(query: @scope.merge(limit: "200")).to_return(body: page([ entry(1, "assistant", "Half a reply.") ], cursor: 1).to_json)
    streams = nil
    assert_no_enqueued_jobs do
      streams = capture_turbo_stream_broadcasts(@conversation) { @conversation.receive_frame(seq: 6, busy: false, tail: "", failure: nil) }
    end
    assert_equal "idle", @conversation.status
    assert_equal [ "Half a reply." ], @conversation.messages.pluck(:content)
    live = "live_conversation_#{@conversation.id}"
    assert_equal [ "messages", live, "status_conversation_#{@conversation.id}", live ], streams.map { it["target"] }
    assert_includes streams.first.to_html, "Half a reply."
    assert_operator streams.last.to_html[/data-seq="(\d+)"/, 1].to_i, :>, 6
    assert_not_includes streams.last.to_html, "Half a reply."
  end

  test "when the last frame's pull fails, the tail stays and a job pulls and clears it" do
    @conversation.update!(status: "running")
    stub_request(:get, @entries).with(query: @scope.merge(limit: "200")).to_return(status: 503)
    streams = nil
    assert_enqueued_with(job: ConversationSyncJob, args: [ @conversation ]) do
      streams = capture_turbo_stream_broadcasts(@conversation) { @conversation.receive_frame(seq: 6, busy: false, tail: "", failure: nil) }
    end
    assert_equal "idle", @conversation.status
    assert_equal [ "status_conversation_#{@conversation.id}" ], streams.map { it["target"] }

    stub_request(:get, @entries).with(query: @scope.merge(limit: "200")).to_return(body: page([ entry(1, "assistant", "Done.") ], cursor: 1).to_json)
    streams = capture_turbo_stream_broadcasts(@conversation) { ConversationSyncJob.perform_now(@conversation) }
    assert_equal %w[ append replace replace ], streams.map { it["action"] }
  end

  test "a reply appended takes its live copy away at once; one that calls a tool leaves Working… there" do
    @conversation.update!(status: "running")
    streams = capture_turbo_stream_broadcasts(@conversation) do
      @conversation.messages.create!(entry_key: "1", entry_id: 1, role: "assistant", content: "Let me look.", tool_calls: [ { "id" => "call_v", "name" => "visit_website" } ])
    end
    assert_equal [ "messages", "live_conversation_#{@conversation.id}" ], streams.map { it["target"] }
    assert_includes streams.last.to_html, "Working…"
    assert_not_includes streams.last.to_html, "Let me look."

    streams = capture_turbo_stream_broadcasts(@conversation) do
      @conversation.messages.create!(entry_key: "3", entry_id: 3, role: "assistant", content: "Done.")
    end
    assert_not_includes streams.last.to_html, "Working…"
  end

  test "a new title shows in the header and in the sidebar" do
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").to_return(status: 202, body: { id: 1 }.to_json)
    stub_request(:get, @entries).with(query: hash_including({})).to_return(body: page([], cursor: nil).to_json)
    streams = capture_turbo_stream_broadcasts(@conversation) { @conversation.submit("Plan my week", request_id: SecureRandom.uuid) }
    titles = streams.select { it["action"] == "update" }
    assert_equal [ "title_conversation_#{@conversation.id}", "nav_title_conversation_#{@conversation.id}" ], titles.map { it["target"] }
    assert titles.all? { it.to_html.include?("Plan my week") }
  end

  test "a page load takes the status from the sidecar, so a lost last frame cannot leave it running" do
    @conversation.update!(status: "running")
    stub_request(:get, "#{SIDECAR}/v1/conversations/12").with(query: @scope)
      .to_return(body: { status: "error", failure: { reason: "model_error" }, pendingInputs: [] }.to_json)

    @conversation.refresh_status!

    assert_equal "error", @conversation.status
    assert_equal "model_error", @conversation.failure
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
