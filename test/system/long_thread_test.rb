require "application_system_test_case"
require_relative "../test_helpers/agent_test_helper"

# An agent's thread runs long: the page shows its newest turns, and scrolling
# up loads earlier ones above without moving what the person is reading.
class LongThreadTest < ApplicationSystemTestCase
  include AgentTestHelper

  setup do
    install_sidecar_settings
    mock_ajent_auth
    visit "/auth/ajent/callback"
    @conversation = create_conversation(User.find_by!(oidc_sub: "42").agents.sole) # tenancy-ok: the test reads the person it signed in
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/12/entries}).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/12(\?.*)?\z}).to_return(body: { status: "idle" }.to_json)
    100.times do |n|
      @conversation.messages.create!(entry_key: "e#{n}", entry_id: n + 1, role: n.even? ? "user" : "assistant", content: "Message #{n + 1}")
    end
  end
  teardown do
    remove_sidecar_settings
    OmniAuth.config.mock_auth[:ajent] = nil
  end

  test "scrolling up loads earlier messages above, keeps the reader's place, and stops at the start" do
    visit conversation_path(@conversation)
    assert_selector "#messages > .ui-message", count: Conversation::Page::SIZE
    # The thread has opened at its end once the earlier page has its address;
    # out of view there, it must not load until scrolled to.
    assert_selector "turbo-frame.chat__earlier[src]", visible: :all
    sleep 0.3
    assert_no_text "Message 60"

    reading = find("#message_#{@conversation.messages.find_by!(entry_id: 61).id}")
    # Measured in the same breath as the scroll, before the earlier page can arrive.
    before = reading.evaluate_script("(document.querySelector('.chat__viewport').scrollTop = 0, this.getBoundingClientRect().top)")
    assert_text "Message 21"
    assert_in_delta before, reading.evaluate_script("this.getBoundingClientRect().top"), 2

    scroll_to_top
    assert_text "Message 1"
    scroll_to_top
    assert_selector ".ui-message[data-entry-id]", count: 100
    assert_no_selector ".ui-skeleton"
  end

  test "on a computer too, Jump to latest hides while the latest message shows, so a card just above the composer keeps its buttons clear" do
    @conversation.messages.create!(entry_key: "card", entry_id: 101, role: "assistant", content: "I'd like to forget an old note.",
      tool_calls: [ { "id" => "call_card", "name" => "forget_note" } ])
    payload = invocation_payload(@conversation, tool: "forget_note", arguments: { "key" => "old" }, call_id: "call_card")
    Invocation.receive(@conversation, task_id: 7, call_id: "call_card", tool: "forget_note", arguments: payload[:arguments], digest: payload[:digest])
    stub_request(:post, %r{#{SIDECAR}/v1/conversations/12/wakes}).to_return(status: 202, body: "{}")
    page.current_window.resize_to(1280, 900)
    visit conversation_path(@conversation)
    assert_selector ".approval", text: "Allow forget note?"
    wait_until { from_end < 2 }

    # Up a little in the thread's own box, until the card's buttons sit just above the status line and composer.
    execute_script(<<~JS)
      const card = document.querySelector(".approval").getBoundingClientRect(), foot = document.querySelector(".chat__footer").getBoundingClientRect()
      document.querySelector(".chat__viewport").scrollBy(0, card.bottom - foot.top + 4)
    JS
    assert_operator from_end, :>, 48, "scrolled off the end"
    assert_no_selector ".chat__jump"
    hits = evaluate_script(<<~JS)
      [ ...document.querySelectorAll(".approval .ui-card__actions button") ].map(b => { const r = b.getBoundingClientRect()
        return document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2) === b ? b.textContent.trim() : "covered" })
    JS
    assert_equal [ "Allow once", "Always for this agent", "Deny" ], hits

    # Well up, the pill is back, and takes the reader to the end.
    execute_script("document.querySelector('.chat__viewport').scrollBy(0, -900)")
    assert_selector ".chat__jump"
    find(".chat__jump").click
    wait_until { from_end < 2 }
    assert_no_selector ".chat__jump"

    click_on "Deny"
    assert_selector ".ui-trace", text: "Declined forget note"
  end

  private
    def from_end = evaluate_script("(v => v.scrollHeight - v.scrollTop - v.clientHeight)(document.querySelector('.chat__viewport'))")
    def scroll_to_top = execute_script("document.querySelector('.chat__viewport').scrollTop = 0")
end
