require "application_system_test_case"
require_relative "../test_helpers/agent_test_helper"

# The agent list beside a thread, kept live over the person's list stream
# (Conversation::Standing, agent_list_controller): rows change, move, come
# and go without a reload.
class AgentListTest < ApplicationSystemTestCase
  include AgentTestHelper

  setup do
    install_sidecar_settings
    mock_ajent_auth
    visit "/auth/ajent/callback"
    @user = User.find_by!(oidc_sub: "42") # tenancy-ok: the test reads the person it signed in
    @open = create_conversation(@user.agents.sole)
    @other = create_conversation(@open.agent, durable_id: "21")
    @other.update!(last_message_at: 1.hour.ago)
    stub_request(:get, "#{SIDECAR}/v1/conversations/12").with(query: hash_including({})).to_return(body: { status: "idle", failure: nil, pendingInputs: [] }.to_json)
    stub_request(:get, "#{SIDECAR}/v1/conversations/12/entries").with(query: hash_including({})).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
  end
  teardown { remove_sidecar_settings }

  test "an agent that needs you moves to the top, a new one appears, an archived one leaves, and the open one stays marked" do
    visit conversation_path(@open)
    assert_equal rows(@open, @other), sidebar

    @other.update!(status: "waiting")
    assert_selector ".chat-sidebar #{rows(@other).first}[data-standing=needs_you]:first-child"
    assert_equal rows(@other, @open), sidebar

    @open.update!(status: "running")
    assert_selector "#{rows(@open).first}[data-standing=working] a[aria-current=page]"
    @open.update!(current_tool: "bash")
    assert_selector "#{rows(@open).first} a[aria-current=page]", text: "Using bash…"

    researcher = @user.start_agent("Researcher").conversation
    assert_selector ".chat-sidebar #{rows(researcher).first}", text: "Researcher"
    assert_equal rows(@other, @open, researcher), sidebar, "needs you, working, then idle"

    @other.archive
    assert_no_selector rows(@other).first
  end

  test "a reply that arrives while its thread is open is read, so the row doesn't turn unread" do
    visit conversation_path(@open)
    assert_selector "#{rows(@open).first} a[aria-current=page]"

    @open.messages.create!(entry_key: "1", entry_id: 1, role: "assistant", content: "Booked.")
    assert_selector ".ui-bubble", text: "Booked."
    50.times { break unless @open.reload.unread?; sleep 0.1 }
    assert_not @open.reload.unread?

    @other.messages.create!(entry_key: "1", entry_id: 1, role: "assistant", content: "Here are three options.")
    assert_selector "#{rows(@other).first}[data-standing=unread]", text: "Here are three options."
    assert_equal rows(@other, @open), sidebar, "unread above idle"
  end

  private
    def rows(*conversations) = conversations.map { "#row_conversation_#{it.id}" }
    def sidebar = all(".chat-sidebar .conversation-row").map { "##{it[:id]}" }
end
