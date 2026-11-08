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
    sleep 0.3 # time for an earlier page to load, which it must not until scrolled to
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

  private
    def scroll_to_top = execute_script("document.querySelector('.chat__viewport').scrollTop = 0")
end
