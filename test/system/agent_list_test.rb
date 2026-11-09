require "application_system_test_case"
require_relative "../test_helpers/agent_test_helper"

# The agent list beside a thread, kept live over the person's list stream
# (Conversation::Standing, sidebar_order_controller): rows change, move, come
# and go without a reload, and hold still under the person's hand.
class AgentListTest < ApplicationSystemTestCase
  include AgentTestHelper

  setup do
    install_sidecar_settings
    mock_ajent_auth
    visit "/auth/ajent/callback"
    @user = User.find_by!(oidc_sub: "42") # tenancy-ok: the test reads the person it signed in
    @open = create_conversation(@user.agents.sole)
    @other = create_conversation(@open.agent, durable_id: "21")
    @other.update!(last_message_at: 1.hour.ago, listed_at: 1.hour.ago)
    stub_request(:get, "#{SIDECAR}/v1/conversations/12").with(query: hash_including({})).to_return(body: { status: "idle", failure: nil, pendingInputs: [] }.to_json)
    stub_request(:get, "#{SIDECAR}/v1/conversations/12/entries").with(query: hash_including({})).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
  end
  teardown { remove_sidecar_settings }

  test "an agent that needs you moves to the top, a new one appears, an archived one leaves, and the open one stays marked" do
    visit conversation_path(@open)
    assert_equal rows(@open, @other), sidebar

    @other.update!(status: "waiting")
    assert_selector ".chat-sidebar #{rows(@other).first}[data-standing=needs_you]:first-child"
    assert_order rows(@other, @open)

    @open.update!(status: "running")
    assert_selector "#{rows(@open).first}[data-standing=working] a[aria-current=page]"
    @open.update!(current_tool: "bash")
    assert_selector "#{rows(@open).first} a[aria-current=page]", text: "Using bash…"

    assert_equal rows(@other, @open), sidebar, "working moves nothing"

    researcher = @user.start_agent("Researcher").conversation
    assert_selector ".chat-sidebar #{rows(researcher).first}", text: "Researcher"
    assert_order rows(researcher, @other, @open), "the newest news first"

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
    assert_order rows(@other, @open), "a reply moves up"
  end

  test "a row doesn't move while the pointer is over the list, and does when it leaves" do
    visit conversation_path(@open)
    assert_no_selector "turbo-cable-stream-source:not([connected])", visible: :all
    assert_equal rows(@open, @other), sidebar

    find(".chat-sidebar #{rows(@open).first}").hover
    @other.update!(status: "waiting")
    assert_selector "#{rows(@other).first}[data-standing=needs_you]"
    sleep 2.5
    assert_equal rows(@open, @other), sidebar, "held under the pointer"

    find(".chat-composer, main", match: :first).hover
    assert_selector ".chat-sidebar #{rows(@other).first}:first-child"
  end

  test "a click that ends on another row than it began on opens nothing" do
    visit conversation_path(@open)
    path = current_path
    page.execute_script(<<~JS, rows(@open).first, rows(@other).first)
      document.querySelector(`.chat-sidebar ${arguments[0]} a`).dispatchEvent(new PointerEvent("pointerdown", { bubbles: true }))
      document.querySelector(`.chat-sidebar ${arguments[1]} a`).click()
    JS
    sleep 0.5
    assert_equal path, current_path

    find(".chat-sidebar #{rows(@other).first} a").click
    assert_current_path conversation_path(@other)
  end

  private
    def rows(*conversations) = conversations.map { "#row_conversation_#{it.id}" }
    def sidebar = all(".chat-sidebar .conversation-row").map { "##{it[:id]}" }

    # A move applies a moment after the change, so wait for it.
    def assert_order(expected, message = nil)
      page.document.synchronize { raise Capybara::ExpectationNotMet, message unless sidebar == expected }
    rescue Capybara::ExpectationNotMet
      assert_equal expected, sidebar, message
    end
end
