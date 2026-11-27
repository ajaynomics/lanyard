require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# A workspace's live lists (its agents, its helpers) are heard only by its
# members. A signed stream name never expires, so the channel asks at each
# subscription, and removing someone closes their open connections, whose
# pages then subscribe afresh and are refused.
class WorkspaceStreamsChannelTest < ActionCable::Channel::TestCase
  include AgentTestHelper
  include ActiveJob::TestHelper

  setup do
    @alice, @bob = create_user(name: "Alice"), create_user(name: "Bob")
    @shared = Workspace.create!(name: "Household")
    @shared.memberships.create!(user: @alice, role: "owner")
    @membership = @shared.memberships.create!(user: @bob, role: "member")
    @stream = Turbo::StreamsChannel.signed_stream_name([ @shared, :conversations ])
  end
  teardown { remove_sidecar_settings }

  test "a member hears the shared list, which a thread in it updates" do
    stub_connection current_user: @bob
    subscribe signed_stream_name: @stream

    assert subscription.confirmed?
    assert_has_stream Turbo::StreamsChannel.verified_stream_name(@stream)
    agent = @shared.agents.create!(user: @alice, name: "Shared", instructions: "Help.", model: Agent.models.first)
    assert_turbo_stream_broadcasts [ @shared, :conversations ] do
      agent.conversation.broadcast_row
    end
  end

  test "someone outside the workspace is refused its list" do
    stub_connection current_user: @bob
    subscribe signed_stream_name: Turbo::StreamsChannel.signed_stream_name([ @alice.personal_workspace, :conversations ])

    assert subscription.rejected?
  end

  test "a member hears a shared thread; someone outside, nothing of it" do
    agent = @shared.agents.create!(user: @alice, name: "Shared", instructions: "Help.", model: Agent.models.first)
    stub_connection current_user: @bob
    subscribe signed_stream_name: Turbo::StreamsChannel.signed_stream_name(agent.conversation)
    assert subscription.confirmed?

    stub_connection current_user: create_user(name: "Sam")
    subscribe signed_stream_name: Turbo::StreamsChannel.signed_stream_name(agent.conversation)
    assert subscription.rejected?
  end

  test "a thread's page hears, on subscribing, of entries saved after it was drawn" do
    conversation = saved_thread
    drawn = conversation.last_entry_id
    save_entry(conversation, 3, "Saved between drawing and listening")

    stub_connection current_user: @bob
    subscribe signed_stream_name: Turbo::StreamsChannel.signed_stream_name(conversation), cursor: drawn

    assert subscription.confirmed?
    assert_equal [ refresh ], transmissions
  end

  test "a page that has every entry is told nothing on subscribing, and hears a later one by its broadcast" do
    conversation = saved_thread
    stub_connection current_user: @bob
    subscribe signed_stream_name: Turbo::StreamsChannel.signed_stream_name(conversation), cursor: conversation.last_entry_id

    assert_empty transmissions
    updates = capture_turbo_stream_broadcasts(conversation) { save_entry(conversation, 3, "Saved while listening") }
    assert_equal 1, updates.count { it["action"] == "append" && it.text.include?("Saved while listening") }
    assert_empty transmissions
  end

  test "an entry saved while a page was reconnecting arrives once, when it subscribes again" do
    conversation = saved_thread
    stub_connection current_user: @bob
    stream = Turbo::StreamsChannel.signed_stream_name(conversation)
    subscribe signed_stream_name: stream, cursor: conversation.last_entry_id
    unsubscribe

    save_entry(conversation, 3, "Saved while away")
    # The browser subscribes again with the page's identifier, its cursor unchanged.
    subscribe signed_stream_name: stream, cursor: 2

    assert_equal [ refresh ], transmissions
  end

  test "a cursor never opens a thread to someone outside its workspace" do
    conversation = saved_thread
    save_entry(conversation, 3, "Not theirs")

    stub_connection current_user: create_user(name: "Sam")
    subscribe signed_stream_name: Turbo::StreamsChannel.signed_stream_name(conversation), cursor: 0

    assert subscription.rejected?
    assert_empty transmissions
    assert_no_enqueued_jobs only: ConversationSyncJob
  end

  # The status, the waiting list and the status line move without an entry, so
  # the cursor can't say the page missed them; only the sidecar knows what waits.
  test "a page drawn as working hears, once it listens, that the run ended and what waits, though the sync finished first" do
    conversation = saved_thread
    conversation.update!(status: "running", execution_status: "running")
    sidecar_says conversation, status: "idle", queued: [ { id: "31", mode: "followUp", text: "Rome, not Paris", pictures: 0 } ]
    ConversationSyncJob.perform_now(conversation, refresh: true)

    stub_connection current_user: @bob
    updates = capture_turbo_stream_broadcasts(conversation) do
      subscribe signed_stream_name: Turbo::StreamsChannel.signed_stream_name(conversation), cursor: conversation.last_entry_id
      perform_enqueued_jobs(only: ConversationSyncJob)
    end

    assert_empty transmissions
    assert updates.any? { it["target"] == "status_conversation_#{conversation.id}" && it.to_html.include?('data-status="idle"') }
    assert updates.any? { it["target"] == "live_conversation_#{conversation.id}" && it.css(".ui-typing").none? }
    assert updates.any? { it["target"] == "queued_conversation_#{conversation.id}" && it.text.include?("Rome, not Paris") }
    assert updates.any? { it["target"] == "status_summary_conversation_#{conversation.id}" }
  end

  test "a page drawn after the sync finished, its status already right, still gets the waiting list once it listens" do
    conversation = saved_thread
    sidecar_says conversation, status: "idle", queued: [ { id: "32", mode: "steer", text: "Make it Lisbon", pictures: 0 } ]
    ConversationSyncJob.perform_now(conversation, refresh: true)
    assert_equal "idle", conversation.reload.shown_status

    stub_connection current_user: @bob
    updates = capture_turbo_stream_broadcasts(conversation) do
      subscribe signed_stream_name: Turbo::StreamsChannel.signed_stream_name(conversation), cursor: conversation.last_entry_id
      perform_enqueued_jobs(only: ConversationSyncJob)
    end

    assert updates.any? { it["target"] == "status_conversation_#{conversation.id}" && it.to_html.include?('data-status="idle"') }
    assert updates.any? { it["target"] == "queued_conversation_#{conversation.id}" && it.text.include?("Make it Lisbon") }
  end

  test "a removed member's open connections close, and the list refuses them after" do
    assert_broadcasts "action_cable/#{@bob.to_gid_param}", 1 do
      @membership.destroy!
    end

    stub_connection current_user: @bob
    subscribe signed_stream_name: @stream
    assert subscription.rejected?
  end

  private
    def saved_thread
      agent = @shared.agents.create!(user: @alice, name: "Shared", instructions: "Help.", model: Agent.models.first)
      create_conversation(agent).tap do |conversation|
        save_entry(conversation, 1, "Hello")
        save_entry(conversation, 2, "Hi.", role: "assistant")
      end
    end

    # As Conversation#sync! records a page of entries and its cursor together.
    def save_entry(conversation, id, content, role: "user")
      conversation.transaction do
        conversation.messages.create!(entry_key: id.to_s, entry_id: id, role: role, content: content)
        conversation.update!(last_entry_id: id)
      end
    end

    def refresh = Turbo::StreamsChannel.turbo_stream_refresh_tag

    def sidecar_says(conversation, status:, queued: [])
      install_sidecar_settings
      stub_request(:get, "#{SIDECAR}/v1/conversations/#{conversation.durable_id}").with(query: hash_including({}))
        .to_return(body: { status: status, failure: nil, pendingInputs: [], queued: queued }.to_json)
      stub_request(:get, "#{SIDECAR}/v1/conversations/#{conversation.durable_id}/entries").with(query: hash_including({}))
        .to_return(body: { entries: [], cursor: conversation.last_entry_id, more: false }.to_json)
    end
end
