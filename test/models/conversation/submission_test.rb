require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

class Conversation::SubmissionTest < ActiveSupport::TestCase
  include AgentTestHelper

  setup do
    install_sidecar_settings
    @agent = create_user.agents.sole
    @conversation = create_conversation(@agent)
    @url = "#{SIDECAR}/v1/conversations/12/submissions"
    stub_request(:get, "#{SIDECAR}/v1/conversations/12/entries").with(query: hash_including({}))
      .to_return(body: { entries: [], cursor: nil }.to_json)
  end
  teardown { remove_sidecar_settings }

  test "a lost response replays identical bytes after midnight and edits instead of rebuilding context" do
    travel_to Time.utc(2026, 11, 14, 23, 59)
    @agent.update!(time_zone: "UTC")
    skill = @agent.skills.create!(name: "trip", description: "Plan a trip", body: "Ask where first.")
    document = @agent.documents.create!(title: "Trip")
    document.revise("Monday\n", by: "agent")
    captured = document.revise("Tuesday\n", by: "person")
    sent = []
    stub_request(:post, @url).with { sent << it.body; true }.to_timeout
    assert_raises(DurableAssistants::PiDurable::Client::Error) do
      @conversation.submit("/skill:trip Lisbon", request_id: "lost")
    end

    travel 2.minutes
    @agent.update!(instructions: "The new instructions.")
    skill.update!(body: "The new skill.")
    document.revise("Wednesday\n", by: "person")
    stub_request(:post, @url).with { sent << it.body; true }.to_return(status: 202, body: { id: 61 }.to_json)
    @conversation.reload.submit("/skill:trip Lisbon", request_id: "lost")

    assert_equal 2, sent.size
    first, last = sent.map { JSON.parse(it) }
    assert_equal first.except("definition"), last.except("definition"), "the words and context go as first prepared"
    assert_match "The new instructions.", last.dig("definition", "instructions"),
      "the settings go as they are now: a late retry never puts back what was changed"
    assert_equal captured.id, document.reload.seen_version_id
    assert document.changed_since_seen?, "the newer edit was not in the prepared message"
    assert_equal Date.new(2026, 11, 14), @conversation.reload.dated_on
  ensure
    travel_back
  end

  test "the person's own send says so, so his steer goes ahead of others'; mail arriving does not" do
    sent = []
    stub_request(:post, @url).with { sent << JSON.parse(it.body); true }.to_return(status: 202, body: { id: 63, status: "queued" }.to_json)
    @conversation.receive("Rome?", from: "acme/sam", via: "Concourse", request_id: "concourse:sam", when_busy: "steer")
    @conversation.submit("Stop, I changed my mind", request_id: "stop", when_busy: "steer")

    assert_equal [ [ "concourse:sam", nil ], [ "stop", true ] ], sent.map { [ it["requestId"], it["fromPerson"] ] }
  end

  test "a picture the model refuses frees the id, so words only can go under it" do
    picture = Rack::Test::UploadedFile.new(StringIO.new("\x89PNG\r\n\x1a\n#{"\0" * 32}".b), "image/png", original_filename: "a.png")
    stub_request(:post, @url).to_return(status: 422, body: { error: "images_unsupported" }.to_json)
    assert_raises(Conversation::ImagesRefused) { @conversation.submit("Look", request_id: "pic", images: [ picture ]) }

    stub_request(:post, @url).to_return(status: 202, body: { id: 62 }.to_json)
    assert_nothing_raised { @conversation.submit("Look", request_id: "pic") }
    assert_equal({ "id" => 62 }, @conversation.submissions.find_by!(request_id: "pic").receipt)
  end

  test "a retry after a newer send does not put back the agent's older settings" do
    sent = []
    stub_request(:post, @url).with { sent << JSON.parse(it.body); true }.to_timeout
    assert_raises(DurableAssistants::PiDurable::Client::Error) { @conversation.receive("Mail", from: "a@example.com", via: "Email", request_id: "mail-1") }

    @agent.update!(instructions: "Never use the old tool.")
    stub_request(:post, @url).with { sent << JSON.parse(it.body); true }.to_return(status: 202, body: { id: 63 }.to_json)
    @conversation.reload.submit("Newer", request_id: "newer")
    @conversation.reload.receive("Mail", from: "a@example.com", via: "Email", request_id: "mail-1")

    assert_equal %w[ mail-1 newer mail-1 ], sent.pluck("requestId")
    assert_match "Never use the old tool.", sent.last.dig("definition", "instructions")
    assert_equal sent[1]["definition"], sent.last["definition"]
  end

  test "a message from outside is cut to the room the notices leave, never refused" do
    20.times do |index|
      @conversation.helpers.create!(call_id: "toolu_#{index}", task: "t" * 300, state: "cancelled", finished_at: Time.current)
    end
    sent = []
    stub_request(:post, @url).with { sent << JSON.parse(it.body); true }.to_return(status: 202, body: { id: 64 }.to_json)

    assert_nothing_raised { @conversation.receive("x" * 70_000, from: "a@example.com", via: "Email", request_id: "long") }
    body = sent.sole["content"]
    assert_includes body, "<helpers_cancelled>"
    assert_operator Conversation.utf16_length(body), :<=, Conversation::Submission::LIMIT
    assert_includes body, Conversation::CUT
  end

  # A sidecar that admits a request id once, as agent/runtime.mjs and
  # pi-durable do, and answers too late as often as `late` says.
  def sidecar_answering_late(times)
    admitted, posts = {}, []
    stub_request(:post, @url).to_return do |request|
      request_id = JSON.parse(request.body).fetch("requestId")
      posts << request_id
      admitted[request_id] ||= 70 + admitted.size
      raise Net::ReadTimeout if posts.size <= times
      { status: 202, body: { id: admitted[request_id], status: "queued" }.to_json }
    end
    [ admitted, posts ]
  end

  test "a busy agent's sidecar that takes a steer but answers too late reports it delivered, once" do
    @conversation.settle(execution: "running")
    admitted, posts = sidecar_answering_late(1)

    receipt = @conversation.receive("Rome?", from: "acme/sam", via: "Concourse mail", request_id: "concourse:rome", when_busy: "steer")
    assert_equal 70, receipt["id"], "the send the sidecar took is reported delivered"
    @conversation.reload.receive("Rome?", from: "acme/sam", via: "Concourse mail", request_id: "concourse:rome", when_busy: "steer")

    assert_equal %w[ concourse:rome concourse:rome ], posts, "asked again under the same id, and a later sweep sends nothing"
    assert_equal 1, admitted.size
    assert_equal "running", @conversation.reload.execution_status
  end

  test "a send that gets no answer twice says retrying is safe, and the retry under its id arrives once" do
    @conversation.settle(execution: "running")
    admitted, posts = sidecar_answering_late(2)

    error = assert_raises(DurableAssistants::PiDurable::Client::Error) do
      @conversation.receive("Rome?", from: "acme/sam", via: "Concourse mail", request_id: "concourse:rome", when_busy: "steer")
    end
    assert error.unanswered?
    assert_match "same request id", error.message

    receipt = @conversation.reload.receive("Rome?", from: "acme/sam", via: "Concourse mail", request_id: "concourse:rome", when_busy: "steer")
    assert_equal 70, receipt["id"]
    assert_equal [ "concourse:rome" ] * 3, posts
    assert_equal 1, admitted.size
  end

  test "a send that never reached the sidecar is not asked again" do
    sent = stub_request(:post, @url).to_raise(Errno::ECONNREFUSED)
    error = assert_raises(DurableAssistants::PiDurable::Client::Error) { @conversation.submit("Hi", request_id: "refused") }
    assert_not error.unanswered?
    assert_requested sent, times: 1
  end

  test "an accepted retry returns its receipt without dispatching or reviving idle work" do
    sent = stub_request(:post, @url).to_return(status: 202, body: { id: 61 }.to_json)
    @conversation.submit("Once", request_id: "once")
    @conversation.settle(execution: "idle")
    @conversation.archive
    @conversation.submit("Once", request_id: "once")

    assert_requested sent, times: 1
    assert_equal "idle", @conversation.reload.status
    assert @conversation.archived?, "a cached acceptance is not a new message"
  end

  test "the date acknowledgment describes the captured date even if acceptance arrives on the next day" do
    travel_to Time.utc(2026, 11, 14, 23, 59)
    @agent.update!(time_zone: "UTC")
    sent = nil
    stub_request(:post, @url).to_return do |request|
      sent = JSON.parse(request.body)
      travel 2.minutes
      { status: 202, body: { id: 61 }.to_json }
    end
    @conversation.submit("At midnight", request_id: "date")

    assert_includes sent.fetch("content"), "2026-11-14"
    assert_equal Date.new(2026, 11, 14), @conversation.reload.dated_on
    assert @conversation.date_note, "the next day's notice remains pending"
  ensure
    travel_back
  end

  test "changed raw text, mode, picture bytes or channel identity conflict before another dispatch" do
    sent = stub_request(:post, @url).to_return(status: 202, body: { id: 61 }.to_json)
    @conversation.submit("One", request_id: "same", images: [ picture ])
    assert_raises(Conversation::Submission::Conflict) { @conversation.submit("Two", request_id: "same", images: [ picture ]) }
    assert_raises(Conversation::Submission::Conflict) { @conversation.submit("One", request_id: "same", when_busy: "followUp", images: [ picture ]) }
    assert_raises(Conversation::Submission::Conflict) { @conversation.submit("One", request_id: "same", images: [ picture("different") ]) }
    assert_raises(Conversation::Submission::Conflict) do
      @conversation.receive("One", from: "Maya", via: "Email", answer: "Reply by email.", request_id: "same")
    end
    assert_requested sent, times: 1
  end

  test "an accepted image retry can use another filename and retains no duplicate image body" do
    sent = stub_request(:post, @url).to_return(status: 202, body: { id: 61 }.to_json)
    first = @conversation.submit("One", request_id: "picture", images: [ picture(filename: "one.jpg") ])
    again = @conversation.reload.submit("One", request_id: "picture", images: [ picture(filename: "two.jpg") ])
    assert_equal({ "id" => 61 }, first)
    assert_equal first, again
    assert_requested sent, times: 1
    record = @conversation.submissions.sole
    assert record.accepted_at && record.acknowledged_at && record.compacted_at
    assert_nil record.payload
    assert_match(/\A[0-9a-f]{64}\z/, record.payload_digest)
  end

  test "a receipt saved before an acknowledgment crash resumes context bookkeeping without network" do
    document = @agent.documents.create!(title: "Plan")
    captured = document.revise("One\n", by: "person")
    prepared = Conversation::Submission.prepare(@conversation, "Once", request_id: "crash", when_busy: "steer")
    prepared.update!(receipt: { id: 61 }, accepted_at: Time.current)
    document.revise("Later\n", by: "person")
    assert_nil prepared.acknowledged_at
    assert_equal({ "id" => 61 }, @conversation.reload.submit("Once", request_id: "crash"))
    assert_not_requested :post, @url
    assert_equal captured.id, document.reload.seen_version_id
    assert document.changed_since_seen?
    assert prepared.reload.acknowledged_at
    assert_nil prepared.payload
  end

  test "an acknowledgment saved before compaction is repeatable and does not wake finished work" do
    prepared = Conversation::Submission.prepare(@conversation, "Once", request_id: "compact", when_busy: "steer")
    prepared.update!(receipt: { id: 61 }, accepted_at: Time.current)
    prepared.acknowledge!
    assert prepared.payload
    @conversation.reload.settle(execution: "idle")
    @conversation.submit("Once", request_id: "compact")
    assert_not_requested :post, @url
    assert_equal "idle", @conversation.reload.status
    assert_nil prepared.reload.payload
  end

  test "channel arrival timestamps and report presentation are generated only once" do
    travel_to Time.utc(2026, 11, 14, 12)
    sent = []
    stub_request(:post, @url).with { sent << it.body; true }.to_timeout
    assert_raises(DurableAssistants::PiDurable::Client::Error) do
      @conversation.receive(from: "the helper", via: "Helper", request_id: "helper:h", source: { helper_id: 7 }) do
        [ "The answer", "The original task context." ]
      end
    end
    travel 2.minutes
    stub_request(:post, @url).with { sent << it.body; true }.to_return(status: 202, body: { id: 61 }.to_json)
    @conversation.reload.receive(from: "the helper", via: "Helper", request_id: "helper:h", source: { helper_id: 7 }) do
      flunk "a retry must not rebuild the report"
    end
    assert_equal sent.first, sent.last
    assert_includes JSON.parse(sent.last).fetch("content"), "Received 2026-11-14 04:00 PST"
    assert_raises(Conversation::Submission::Conflict) do
      @conversation.receive(from: "another helper", via: "Helper", request_id: "helper:h", source: { helper_id: 7 })
    end
  ensure
    travel_back
  end

  test "only the captured cancellation IDs are acknowledged after a lost response" do
    old = @conversation.helpers.create!(call_id: "cancelled-one", task: "First task", state: "cancelled")
    sent = []
    stub_request(:post, @url).with { sent << it.body; true }.to_timeout
    assert_raises(DurableAssistants::PiDurable::Client::Error) { @conversation.submit("Go on", request_id: "cancelled") }
    later = @conversation.helpers.create!(call_id: "cancelled-two", task: "Later task", state: "cancelled")
    stub_request(:post, @url).with { sent << it.body; true }.to_return(status: 202, body: { id: 61 }.to_json)
    @conversation.reload.submit("Go on", request_id: "cancelled")
    assert_equal sent.first, sent.last
    assert old.reload.told_at
    assert_nil later.reload.told_at
  end

  test "a summary after preparation leaves its date notice pending" do
    prepared = Conversation::Submission.prepare(@conversation, "Once", request_id: "summary", when_busy: "steer")
    @conversation.messages.create!(role: "summary", entry_id: 20, entry_key: "summary", content: "Earlier messages")
    prepared.update!(receipt: { id: 61 }, accepted_at: Time.current)
    @conversation.reload.submit("Once", request_id: "summary")
    assert_nil @conversation.reload.dated_on
    assert @conversation.date_note
  end

  test "final UTF16 boundaries preserve expanded words and refuse mandatory overflow without acknowledgment" do
    @conversation.update!(dated_on: @conversation.today)
    @agent.prompts.create!(name: "wide", body: "$ARGUMENTS" * 4)
    raw = "/wide #{"😀" * 8_192}"
    sent = []
    stub_request(:post, @url).with { sent << JSON.parse(it.body); true }.to_return(status: 202, body: { id: 61 }.to_json)
    @conversation.submit(raw, request_id: "fits")
    assert_equal 65_536, Conversation.utf16_length(sent.sole.fetch("content"))
    @conversation.update!(dated_on: nil)
    assert_raises(Conversation::Submission::TooLarge) { @conversation.submit(raw, request_id: "too-wide", images: [ picture ]) }
    assert_not @conversation.submissions.exists?(request_id: "too-wide")
    assert_nil @conversation.reload.dated_on
    assert_equal 1, sent.size
  end

  test "raw person input keeps its byte limit even when UTF16 would fit" do
    assert_raises(Conversation::Submission::TooLarge) { @conversation.submit("😀" * 16_385, request_id: "raw") }
    assert_empty @conversation.submissions
    assert_not_requested :post, @url
  end

  test "malformed success does not count as durable acceptance or consume context" do
    document = @agent.documents.create!(title: "Plan")
    document.revise("One", by: "person")
    stub_request(:post, @url).to_return(status: 202, body: "{}")
    assert_raises(DurableAssistants::PiDurable::Client::Error) { @conversation.submit("One", request_id: "bad-receipt") }
    record = @conversation.submissions.sole
    assert_nil record.accepted_at
    assert_nil record.acknowledged_at
    assert record.payload
    assert document.reload.changed_since_seen?
  end

  test "a projection rebuild keeps the same summary identity for an acknowledgment" do
    summary = @conversation.messages.create!(role: "summary", entry_id: 20, entry_key: "summary-key", content: "Earlier messages")
    prepared = Conversation::Submission.prepare(@conversation, "Once", request_id: "resync", when_busy: "steer")
    summary.destroy!
    @conversation.messages.create!(role: "summary", entry_id: 20, entry_key: "summary-key", content: "Earlier messages")
    prepared.update!(receipt: { id: 61 }, accepted_at: Time.current)
    @conversation.reload.submit("Once", request_id: "resync")
    assert_equal prepared.context.fetch("date").to_date, @conversation.reload.dated_on
  end

  test "an old zone's acknowledgment does not suppress the new zone's date notice" do
    @agent.update!(time_zone: "UTC")
    prepared = Conversation::Submission.prepare(@conversation, "Once", request_id: "zone", when_busy: "steer")
    @agent.update!(time_zone: "Pacific Time (US & Canada)")
    prepared.update!(receipt: { id: 61 }, accepted_at: Time.current)
    @conversation.reload.submit("Once", request_id: "zone")
    assert_nil @conversation.reload.dated_on
    assert @conversation.date_note
  end

  test "pending envelopes are encrypted, filtered on inspection and immutable" do
    canary = "synthetic-private-message-4462"
    prepared = Conversation::Submission.prepare(@conversation, canary, request_id: "private", when_busy: "steer")
    assert_includes prepared.payload, canary
    raw = prepared.class.connection.select_value("SELECT payload FROM conversation_submissions WHERE id = #{prepared.id}")
    assert_not_includes raw, canary
    assert_not_includes prepared.inspect, canary
    original = prepared.payload
    assert_not prepared.update(payload: "{}")
    assert_equal original, @conversation.submissions.find(prepared.id).payload
  end

  test "all context notices fit together without dropping the person's expanded words" do
    document = @agent.documents.create!(title: "Plan")
    document.revise("Old\n" * 3_000, by: "agent")
    target = document.revise("New\n" * 3_000, by: "person")
    helper = @conversation.helpers.create!(call_id: "cancelled", task: "First task", state: "cancelled")
    workflow = @conversation.workflows.create!(name: "Trip", kind: "pipeline", steps: [ { "task" => "Look" } ])
    run = workflow.runs.create!(call_id: "workflow", state: "cancelled")
    sent = nil
    stub_request(:post, @url).to_return { |request| sent = JSON.parse(request.body); { status: 202, body: { id: 61 }.to_json } }
    raw = "a" * 64_000
    @conversation.submit(raw, request_id: "all-context")
    assert sent.fetch("content").start_with?(raw)
    %w[ document_changes helpers_cancelled workflows_cancelled current_date ].each do |notice|
      assert_includes sent.fetch("content"), "<#{notice}>"
    end
    assert_operator Conversation.utf16_length(sent.fetch("content")), :<=, 65_536
    assert_equal target.id, document.reload.seen_version_id
    assert helper.reload.told_at
    assert run.reload.told_at
  end

  test "a helper's existing report retry reuses preparation after the arrival minute changes" do
    sent = []
    stub_request(:post, @url).with { sent << it.body; true }.to_timeout
    assert_raises(DurableAssistants::PiDurable::Client::Error) do
      Helper.report(@conversation, call_id: "h", task: "Look", state: "done", answer: "Found it")
    end
    helper = @conversation.helpers.sole
    assert helper.finished?
    assert_nil helper.delivered_at
    assert_empty @conversation.helpers.running
    travel 2.minutes
    stub_request(:post, @url).with { sent << it.body; true }.to_return(status: 202, body: { id: 61 }.to_json)
    Helper.report(@conversation.reload, call_id: "h", task: "Look", state: "done", answer: "Found it")
    assert_equal sent.first, sent.last
    assert helper.reload.delivered_at
    assert_equal 1, @conversation.submissions.count
  ensure
    travel_back
  end

  test "a workflow's existing advance retry keeps the original report and task context" do
    workflow = @conversation.workflows.create!(name: "Hotels", kind: "pipeline", steps: [ { "task" => "Look" } ])
    run = workflow.start(call_id: "w")
    run.steps.sole.update!(state: "done", answer: "Found it")
    run.update!(state: "done")
    sent = []
    stub_request(:post, @url).with { sent << it.body; true }.to_timeout
    assert_raises(DurableAssistants::PiDurable::Client::Error) { run.advance }
    assert_nil run.reload.delivered_at
    travel 2.minutes
    workflow.update!(name: "New task context")
    stub_request(:post, @url).with { sent << it.body; true }.to_return(status: 202, body: { id: 61 }.to_json)
    run.reload.advance
    assert_equal sent.first, sent.last
    assert run.reload.delivered_at
    assert_not @conversation.workflow_runs.unsettled.exists?(id: run.id)
    assert_equal 1, @conversation.submissions.count
  ensure
    travel_back
  end

  private
    def picture(extra = "", filename: "picture.jpg")
      StringIO.new("\xFF\xD8\xFF fixture#{extra}".b).tap { |file| file.define_singleton_method(:original_filename) { filename } }
    end
end
