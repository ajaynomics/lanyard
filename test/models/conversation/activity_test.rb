require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

# Attention and execution apart (Conversation::Activity): a card waiting on
# the person says nothing about whether the agent's own run is going, and
# answering one never makes it go. Background helpers' cards are the case
# that tells them apart: the parent can finish while they wait.
class Conversation::ActivityTest < ActiveSupport::TestCase
  include AgentTestHelper
  include ActionCable::TestHelper
  include ActiveJob::TestHelper

  # Conversation::STATUSES at 8739d91, the release before execution_status.
  OLD_STATUSES = %w[ idle running waiting error ].freeze

  setup do
    install_sidecar_settings
    @agent = create_user.agents.sole
    @conversation = create_conversation(@agent)
    @conversation.helpers.create!(call_id: "toolu_h", task: "Find a hotel.")
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/\d+/entries}).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
  end
  teardown { remove_sidecar_settings }

  test "the parent finishing with two background cards waiting leaves the thread waiting and its run idle" do
    frame busy: true
    card "toolu_h/toolu_a"
    card "toolu_h/toolu_b"
    frame busy: false

    assert_equal %w[ waiting idle ], standing
    assert_nil @conversation.failure
    assert_equal 2, @conversation.user.needs_you_count, "the badge counts both cards"
  end

  test "a page load takes the run from the sidecar and the attention from the cards, again on every reload" do
    card "toolu_h/toolu_a"
    snapshot "done"

    2.times do
      @conversation.reload.refresh_status!
      assert_equal %w[ waiting idle ], standing
    end

    snapshot "running"
    @conversation.reload.refresh_status!
    assert_equal %w[ waiting running ], standing
  end

  test "answering one card leaves the thread waiting on the other; answering the last shows the idle parent, never working" do
    frame busy: true
    first, last = card("toolu_h/toolu_a"), card("toolu_h/toolu_b")
    frame busy: false

    first.update!(state: "approved")
    assert_equal %w[ waiting idle ], standing

    streams = capture_turbo_stream_broadcasts(@conversation) { last.update!(state: "succeeded", result: { "answer" => "Yes" }) }
    assert_equal %w[ idle idle ], standing
    assert_no_match(/data-status="running"/, streams.map(&:to_html).join, "no phantom working after the final background card")
    assert_equal "idle", @conversation.standing
  end

  test "a denied card, an expired card and a failed run each settle without inventing work, and the failure is kept" do
    frame busy: true
    denied = card("toolu_h/toolu_a")
    expiring = card("toolu_h/toolu_b", expires_at: 5.minutes.from_now)
    frame busy: false, failure: "model_error"
    assert_equal %w[ waiting error ], standing
    assert_equal "model_error", @conversation.failure
    assert_equal "needs_you", @conversation.standing, "the card is what the person must act on first"
    html = ApplicationController.render(partial: "conversations/status", locals: { conversation: @conversation })
    assert_includes html, "Waiting for you · stopped:"

    denied.update!(state: "denied")
    assert_equal %w[ waiting error ], standing

    travel 10.minutes do
      expiring.advance
      assert expiring.reload.failed?
      assert_equal %w[ error error ], standing
      assert_equal "model_error", @conversation.failure
    end
  end

  test "a card that expired holds no attention, whatever else changes" do
    card "toolu_h/toolu_a", expires_at: 5.minutes.from_now
    travel 10.minutes do
      frame busy: false
      assert_equal %w[ idle idle ], standing
    end
  end

  test "a final frame, a working frame and a card arriving in any order leave the same thread" do
    orders = [ %i[ busy card final ], %i[ card busy final ], %i[ busy final card ], %i[ card final ] ]
    orders.each_with_index do |order, index|
      @conversation = create_conversation(@agent, durable_id: "2#{index}")
      @conversation.helpers.create!(call_id: "toolu_h", task: "Find a hotel.")
      order.each do |step|
        case step
        when :busy then frame busy: true
        when :final then frame busy: false
        when :card then card "toolu_h/toolu_a"
        end
      end
      assert_equal %w[ waiting idle ], standing, order.inspect
    end
  end

  test "a card on the agent's own call keeps the run working underneath, and answering it shows it working again" do
    frame busy: true
    own = card("toolu_1")
    assert_equal %w[ waiting running ], standing

    own.update!(state: "succeeded", result: {})
    assert_equal %w[ running running ], standing
  end

  test "a card never changes the run: idle stays idle, and a run Rails can't vouch for says so" do
    background = card("toolu_h/toolu_a")
    assert_equal %w[ waiting idle ], standing
    background.update!(state: "denied")
    assert_equal %w[ idle idle ], standing

    @conversation.update!(execution_status: "unknown")
    unsure = card("toolu_h/toolu_b")
    assert_equal %w[ waiting unknown ], standing
    unsure.update!(state: "denied")
    assert_equal %w[ unknown unknown ], standing

    html = ApplicationController.render(partial: "conversations/status", locals: { conversation: @conversation })
    assert_includes html, "Checking run status"
    assert @conversation.live_reply?, "a reply may still be coming"
    assert_equal "unknown", @conversation.standing
    assert_equal "Checking run status", ApplicationController.helpers.standing_title(@conversation, "unknown")
  end

  # During a deploy the release before runs beside this one: a run it starts
  # is recorded only as status "running". The sweep asks about it, and its end
  # is told as any run's.
  test "a run the release before started, recorded only in status, is swept and its end told" do
    @conversation.messages.create!(entry_key: "a1", entry_id: 1, role: "assistant", content: "Booked.")
    @conversation.update_columns(status: "running", execution_status: "idle")
    assert_includes Conversation.where(execution_status: %w[ running unknown ]).or(Conversation.where(status: "running")), @conversation
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/12(\?.*)?\z}).to_return(body: { status: "idle" }.to_json)
    told = []
    @conversation.define_singleton_method(:notify) { |_member, **notice| told << notice[:kind] }

    @conversation.settle(execution: "idle")

    assert_equal %w[ reply ], told
    assert_equal %w[ idle idle ], standing
  end

  test "only a first accepted send marks the run; a cached acceptance retried after the run ended never revives it" do
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").to_return(status: 202, body: { id: 61, status: "queued" }.to_json)
    @conversation.submit("Go on", request_id: "go")
    assert_equal %w[ running running ], standing

    frame busy: false
    # The process stopped between the sidecar's receipt and Rails' acknowledgment.
    @conversation.submissions.sole.update_columns(acknowledged_at: nil)
    @conversation.reload.submit("Go on", request_id: "go")

    assert_equal %w[ idle idle ], standing
    assert @conversation.submissions.sole.acknowledged_at
  end

  test "a card arriving or ending while the thread stays waiting redraws the row and the card above the box" do
    card "toolu_h/toolu_a"
    rows = capture_turbo_stream_broadcasts([ @conversation.workspace, :conversations ]) do
      @needs_you = capture_turbo_stream_broadcasts(@conversation) { card "toolu_h/toolu_b", question: "Which hotel?" }
    end
    assert_equal "waiting", standing.first
    assert_includes rows.map(&:to_html).join, "Which hotel?"
    assert @needs_you.any? { it["target"] == "needs_you_conversation_#{@conversation.id}" && it.to_html.include?("and 1 more") }
  end

  # The stall guard handles only `stalled`, but the sidecar can report `waiting`
  # for calls Rails already answered. Don't show typing dots for those waits.
  test "the stall guard handles only stalled: waits held only for calls already answered are not a running run" do
    frame busy: true
    posted = own_call("task-posted", "call-posted", state: "succeeded", result: { "posted" => true })
    refused = own_call("task-refused", "call-refused", state: "failed", error: "campfire_say failed")
    snapshot "waiting", waits: [ posted, refused ]

    @conversation.reload.refresh_status!

    assert_equal %w[ unknown unknown ], standing, "the sidecar is asked again; nothing shows typing meanwhile"
    assert_enqueued_jobs 2, only: InvocationWakeJob

    still_posting = own_call("task-running", "call-running", state: "running")
    snapshot "waiting", waits: [ posted, still_posting ]
    @conversation.reload.refresh_status!
    assert_equal %w[ running running ], standing, "a wait on a call still running is the run going"
  end

  private
    def standing
      @conversation.reload
      assert_includes OLD_STATUSES, @conversation.status, "code from before execution_status, beside this in a deploy, could not save it"
      [ @conversation.shown_status, @conversation.execution_status ]
    end

    def frame(busy:, failure: nil)
      @conversation.reload.receive_frame(seq: (@seq = @seq.to_i + 1), busy: busy, tail: "", failure: failure)
    end

    def snapshot(status, waits: [])
      pending = waits.map { { id: "person:#{it.wait_key}", kind: "person", expiresAt: 1.day.from_now.to_i * 1000 } }
      stub_request(:get, "#{SIDECAR}/v1/conversations/#{@conversation.durable_id}").with(query: hash_including({}))
        .to_return(body: { status: status, failure: nil, pendingInputs: pending, queued: [] }.to_json)
    end

    def own_call(task_id, call_id, **attributes)
      @conversation.invocations.create!(task_id: task_id, call_id: call_id, tool_name: "campfire_say",
        arguments: { "room" => 1, "text" => "On my way" }, digest: "d-#{call_id}", **attributes)
    end

    def card(call_id, expires_at: 1.hour.from_now, question: "Which day?")
      @conversation.invocations.create!(task_id: "7", call_id: call_id, tool_name: "ask_person", arguments: { "question" => question },
        digest: "d-#{call_id}", state: "awaiting_person", expires_at: expires_at)
    end
end
