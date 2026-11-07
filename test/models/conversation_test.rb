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

  test "a person's pictures come back from their committed entry, as thumbnails that open full size" do
    png = Base64.strict_encode64(Base64.strict_decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="))
    stub_request(:get, @entries).with(query: @scope.merge(limit: "200")).to_return(body: page([
      entry(1, "user", "", images: [ { mimeType: "image/png", data: png } ])
    ], cursor: 1).to_json)

    @conversation.sync!

    message = @conversation.messages.sole
    assert_equal "image/png", message.images.sole.content_type
    html = ApplicationController.render(partial: "messages/message", locals: { message: message })
    assert_match %r{<a [^>]*href="/rails/active_storage/blobs/[^"]+\?disposition=inline">\s*<img alt="Picture you sent"}, html
    assert_no_match "ui-bubble", html
  end

  test "a branch forks after a reply, or just before a person's message; a sidecar id already taken is a mismatch, not a guess" do
    first = @conversation.messages.create!(entry_key: "2", entry_id: 2, role: "user", content: "Hi")
    reply = @conversation.messages.create!(entry_key: "3", entry_id: 3, role: "assistant", content: "Hello")
    @conversation.messages.create!(entry_key: "3:1", entry_id: 3, role: "toolResult", content: "")
    again = @conversation.messages.create!(entry_key: "7", entry_id: 7, role: "user", content: "More")
    assert_equal [ nil, 3, 3 ], [ first, reply, again ].map(&:fork_point)

    stub_request(:post, "#{SIDECAR}/v1/conversations/12/forks").to_return(status: 201, body: { id: 12 }.to_json)
    assert_raises(Conversation::Mismatch) { @conversation.branch(request_id: "b-1", after: 3) }
    assert_empty @conversation.branches
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

  test "a sidecar tool's line shows what went in, and its result fills it in, live and on a reload" do
    call = { "id" => "call_b", "name" => "bash", "arguments" => { "command" => "ls -la" } }
    reply = @conversation.messages.create!(entry_key: "1", entry_id: 1, role: "assistant", content: "", tool_calls: [ call ])
    running = ApplicationController.render(partial: "messages/message", locals: { message: reply })
    assert_includes running, "Running bash…"
    assert_includes running, "ls -la"

    streams = capture_turbo_stream_broadcasts(@conversation) do
      @conversation.messages.create!(entry_key: "2", entry_id: 2, role: "toolResult", content: "total 0", tool_name: "bash", tool_call_id: "call_b")
    end
    assert_equal [ [ "replace", Invocation.dom_target("call_b"), "morph" ] ], streams.map { [ it["action"], it["target"], it["method"] ] }
    assert_includes streams.sole.to_html, "Ran bash"
    assert_includes streams.sole.to_html, "total 0"

    html = ApplicationController.render(partial: "messages/message", locals: { message: reply.reload })
    assert_includes html, "Ran bash"
    assert_not_includes html, "Running bash"
    result = ApplicationController.render(partial: "messages/message", locals: { message: @conversation.messages.find_by!(entry_key: "2") })
    assert_empty result.strip
  end

  test "a frame shows what a running sidecar tool printed, by sequence; the bot's own tools are left to their ledger rows" do
    call = { "id" => "call_b", "name" => "bash", "arguments" => { "command" => "make" } }
    reply = @conversation.messages.create!(entry_key: "1", entry_id: 1, role: "assistant", content: "", tool_calls: [ call ])
    assert_includes ApplicationController.render(partial: "messages/message", locals: { message: reply }), %(id="#{Invocation.dom_target('call_b')}_output")

    tools = [ { "callId" => "call_b", "name" => "bash", "status" => "running", "output" => "compiling <main>\n" },
              { "callId" => "call_n", "name" => "forget_note", "status" => "running", "output" => "" } ]
    streams = capture_turbo_stream_broadcasts(@conversation) { @conversation.receive_frame(seq: 7, busy: true, tail: "", failure: nil, tools: tools) }
    output = streams.find { it["target"] == "#{Invocation.dom_target('call_b')}_output" }
    assert_equal [ "replace", "morph" ], [ output["action"], output["method"] ]
    assert_includes output.to_html, 'data-seq="7"'
    assert_includes output.to_html, "compiling &lt;main&gt;"
    assert_not streams.any? { it["target"].start_with?(Invocation.dom_target("call_n")) }

    # The result replaces it, above the frames sent before it; nothing is stored.
    streams = capture_turbo_stream_broadcasts(@conversation) do
      @conversation.messages.create!(entry_key: "2", entry_id: 2, role: "toolResult", content: "built", tool_name: "bash", tool_call_id: "call_b")
    end
    assert_operator streams.sole.to_html[/_output" class="tool-call__output" data-seq="(\d+)"/, 1].to_i, :>, 7
    assert_not_includes streams.sole.to_html, "compiling"
  end

  test "a script's call to a sidecar tool is listed under the script while it prints" do
    tool = { "callId" => "toolu_s/c2", "name" => "bash", "status" => "running", "output" => "line1\n" }
    streams = capture_turbo_stream_broadcasts(@conversation) { @conversation.receive_frame(seq: 9, busy: true, tail: "", failure: nil, tools: [ tool ]) }
    line = streams.find { it["action"] == "append" }
    assert_equal "#{Invocation.dom_target('toolu_s')}_calls", line["target"]
    assert_includes line.to_html, %(id="#{Invocation.dom_target('toolu_s/c2')}" class="tool-call" data-seq="9")
    assert_includes line.to_html, "Running bash…"
    assert_includes line.to_html, "line1"
  end

  test "each reply shows what it used, and the last frame records the conversation's total, cost labelled an estimate" do
    stub_request(:get, @entries).with(query: @scope.merge(limit: "200")).to_return(body: page([
      entry(1, "assistant", "Priced.", usage: { input: 4, output: 312, cacheRead: 1200, cacheWrite: 0, totalTokens: 1516, cost: 0.0213 }),
      entry(2, "assistant", "Unpriced.", usage: { input: 10, output: 5, cacheRead: 0, cacheWrite: 0, totalTokens: 15, cost: 0 }),
      entry(3, "user", "Thanks")
    ], cursor: 3).to_json)
    usage = { input: 14, output: 317, cacheRead: 1200, cacheWrite: 0, totalTokens: 1531, cost: { estimatedTotal: 0.0213, basis: "catalogue_price_estimate" } }
    streams = capture_turbo_stream_broadcasts(@conversation) { @conversation.receive_frame(seq: 3, busy: false, tail: "", failure: nil, usage: usage.deep_stringify_keys) }

    priced, unpriced, person = @conversation.messages.order(:entry_id)
    assert_equal({ "input" => 4, "output" => 312, "cacheRead" => 1200, "cacheWrite" => 0, "totalTokens" => 1516, "cost" => 0.0213 }, priced.usage)
    assert_nil unpriced.usage["cost"]
    assert_nil person.usage
    assert_includes ApplicationController.render(partial: "messages/message", locals: { message: priced }), "1,204 in · 312 out · about $0.02 at API prices"
    line = ApplicationController.render(partial: "messages/message", locals: { message: unpriced })
    assert_includes line, "10 in · 5 out"
    assert_not_includes line, "$"
    unpriced.usage = unpriced.usage.merge("cost" => 0.004)
    assert_includes ApplicationController.render(partial: "messages/message", locals: { message: unpriced }), "10 in · 5 out · under $0.01 at API prices"

    assert_equal 1531, @conversation.reload.usage["totalTokens"]
    total = streams.find { it["target"] == "usage_conversation_#{@conversation.id}" }.to_html
    assert_includes total, "This conversation: 1,531 tokens, about $0.02 at API prices."
    assert_includes total, "an API key is billed at these prices; a subscription is not billed per token"
  end

  test "a code mode script shows itself, and its calls to the bot's tools, approval cards included, inside its line" do
    script = { "id" => "toolu_s", "name" => "codemode", "arguments" => { "code" => "await tools.forget_note({ key: 'dentist' })" } }
    reply = @conversation.messages.create!(entry_key: "1", entry_id: 1, role: "assistant", content: "", tool_calls: [ script ])
    html = ApplicationController.render(partial: "messages/message", locals: { message: reply })
    assert_includes html, "Running code…"
    assert_includes html, "tools.forget_note"

    arguments = { "key" => "dentist" }
    digest = Invocation.digest_for(@conversation, task_id: 31, call_id: "toolu_s/c1", tool: "forget_note", arguments: arguments)
    streams = capture_turbo_stream_broadcasts(@conversation) do
      Invocation.receive(@conversation, task_id: 31, call_id: "toolu_s/c1", tool: "forget_note", arguments: arguments, digest: digest)
    end
    # Running, then waiting for the person: each lands in the script's list, the second over the first.
    assert_equal [ "#{Invocation.dom_target('toolu_s')}_calls" ] * 2, streams.select { it["action"] == "append" }.map { it["target"] }
    card = streams.select { it["action"] == "append" }.last
    assert_includes card.to_html, "Allow forget note?"
    assert_includes ApplicationController.render(partial: "messages/message", locals: { message: reply }), "Allow forget note?"
  end

  test "a helper shows its task, its calls inside its line at any depth, and its answer as text with links" do
    helper = { "id" => "toolu_h", "name" => "subagent", "arguments" => { "task" => "Find the dentist's number." } }
    reply = @conversation.messages.create!(entry_key: "1", entry_id: 1, role: "assistant", content: "", tool_calls: [ helper ])
    html = ApplicationController.render(partial: "messages/message", locals: { message: reply })
    assert_includes html, "Running helper…"
    assert_includes html, "Find the dentist&#39;s number."

    # The helper's own call and a call its script made both land in the helper's line.
    arguments = { "key" => "dentist" }
    %w[ toolu_h/toolu_c toolu_h/toolu_s/c1 ].each_with_index do |call_id, index|
      digest = Invocation.digest_for(@conversation, task_id: 40 + index, call_id: call_id, tool: "forget_note", arguments: arguments)
      streams = capture_turbo_stream_broadcasts(@conversation) do
        Invocation.receive(@conversation, task_id: 40 + index, call_id: call_id, tool: "forget_note", arguments: arguments, digest: digest)
      end
      assert_equal [ "#{Invocation.dom_target('toolu_h')}_calls" ], streams.select { it["action"] == "append" }.map { it["target"] }.uniq
    end
    assert_equal "toolu_h/toolu_s", Invocation.parent_call_id("toolu_h/toolu_s/c1")
    assert_nil Invocation.parent_call_id("toolu_h")

    # A running sidecar call the helper made is listed there too, while it runs.
    streams = capture_turbo_stream_broadcasts(@conversation) do
      @conversation.receive_frame(seq: 7, busy: true, tail: "", failure: nil,
        tools: [ { "callId" => "toolu_h/toolu_b", "name" => "bash", "status" => "running", "output" => "ls" } ])
    end
    line = streams.find { it["action"] == "append" }
    assert_equal "#{Invocation.dom_target('toolu_h')}_calls", line["target"]
    assert_includes line.to_html, "Running bash…"

    result = @conversation.messages.create!(entry_key: "2", entry_id: 2, role: "toolResult", tool_call_id: "toolu_h", tool_name: "subagent",
      content: "It is [555-0100](https://example.com/dentist).")
    html = ApplicationController.render(partial: "messages/tool_call", locals: { call: helper, result: result, invocations: @conversation.invocations.index_by(&:call_id) })
    assert_includes html, "Ran helper"
    assert_includes html, '<a href="https://example.com/dentist">555-0100</a>'
    assert_equal 2, html.scan("Allow forget note?").size
  end

  test "a web search shows its query, and its answer with clickable sources" do
    search = { "id" => "toolu_w", "name" => "web_search", "arguments" => { "query" => "rails 8.2 release" } }
    reply = @conversation.messages.create!(entry_key: "1", entry_id: 1, role: "assistant", content: "", tool_calls: [ search ])
    assert_includes ApplicationController.render(partial: "messages/message", locals: { message: reply }), "Running web search…"

    result = @conversation.messages.create!(entry_key: "2", entry_id: 2, role: "toolResult", tool_call_id: "toolu_w", tool_name: "web_search",
      content: "Rails 8.2 is out.\n\nSources:\n- [Rails 8.2 released](https://rubyonrails.org/2026/11/rails-8-2)\n- [Bad](javascript:alert(1))")
    html = ApplicationController.render(partial: "messages/tool_call", locals: { call: search, result: result })
    assert_includes html, "Ran web search"
    assert_includes html, "rails 8.2 release"
    assert_includes html, '<a href="https://rubyonrails.org/2026/11/rails-8-2">Rails 8.2 released</a>'
    assert_not_includes html, "javascript:"
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

  test "a skill or saved prompt is expanded before it goes, and the title keeps what the person typed" do
    @bot.skills.create!(name: "trip", description: "Plans trips.", body: "Ask where first.")
    sent = []
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").with { sent << JSON.parse(it.body) }.to_return(status: 202, body: { id: 1 }.to_json)
    stub_request(:get, @entries).with(query: hash_including({})).to_return(body: page([], cursor: nil).to_json)

    @conversation.submit("/skill:trip to Lisbon", request_id: "m-1")
    @conversation.submit("/unknown stays", request_id: "m-2")

    assert_equal [ %(<skill name="trip" location="skill:trip">\nAsk where first.\n</skill>\n\nto Lisbon), "/unknown stays" ], sent.pluck("content")
    assert_equal "/skill:trip to Lisbon", @conversation.reload.title
    assert_equal @bot.definition[:digest], sent.first.dig("definition", "digest")
  end

  test "renaming broadcasts the new title, escaped" do
    streams = capture_turbo_stream_broadcasts(@conversation) { @conversation.update!(title: "Trip <plans>") }
    assert_equal [ "title_conversation_#{@conversation.id}", "nav_title_conversation_#{@conversation.id}" ], streams.map { it["target"] }
    assert streams.all? { it.to_html.include?("Trip &lt;plans&gt;") }
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
