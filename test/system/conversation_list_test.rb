require "application_system_test_case"
require_relative "../test_helpers/agent_test_helper"

# Finding, archiving and moving along conversations in a real browser.
class ConversationListTest < ApplicationSystemTestCase
  include AgentTestHelper

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    @bot = User.find_by!(oidc_sub: "42").bots.sole # tenancy-ok: the test reads the person it signed in
    # Every conversation page load asks the sidecar for news; there is none.
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/[^/]+/entries}).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/[^/?]+(\?.*)?\z}).to_return(body: { status: "idle" }.to_json)
  end
  teardown do
    remove_sidecar_settings
    OmniAuth.config.mock_auth[:ajent] = nil
  end

  test "search finds a conversation by the words in its messages" do
    conversation("Weekend").messages.create!(entry_key: "1", entry_id: 1, role: "assistant", content: "Try the pastéis in Belém")
    conversation("Groceries")

    visit bot_conversations_path(@bot)
    assert_selector ".conversation-row", count: 2
    find("body").send_keys("/")
    assert_equal "q", page.evaluate_script("document.activeElement.name")
    fill_in "Search agents", with: "pastéis\n"

    assert_selector ".conversation-row", count: 1
    assert_selector ".conversation-row__link", text: "Weekend"
    assert_field "Search agents", with: "pastéis"
    assert_includes URI.decode_www_form_component(current_url), "q=pastéis"

    fill_in "Search agents", with: "zebra\n"
    assert_text 'Nothing matches "zebra".'
    click_on "Clear"
    assert_selector ".conversation-row", count: 2
  end

  test "archiving hides a conversation from the sidebar, and unarchiving brings it back" do
    other = conversation("Other")
    talk = conversation("Talk")

    visit conversation_path(other)
    assert_selector ".chat-sidebar .conversation-row__link", text: "Talk"
    click_on "Talk"
    click_on "Archive agent"

    assert_button "Unarchive agent"
    assert_no_selector ".chat-sidebar .conversation-row__link", text: "Talk"
    assert talk.reload.archived?

    click_on "Unarchive agent"
    assert_selector ".chat-sidebar .conversation-row__link", text: "Talk"
    assert_not talk.reload.archived?

    visit bot_conversations_path(@bot)
    within(".conversation-row", text: "Talk") { click_on "Archive" }
    assert_no_selector ".conversation-row__link", text: "Talk"
    select "Archived", from: "Show"
    assert_selector ".conversation-row__link", text: "Talk"
  end

  test "the sidebar loads the thirty-first conversation as it scrolls" do
    talks = 31.times.map { |index| conversation("Talk #{index}", last_message_at: index.minutes.ago) }

    visit conversation_path(talks.first)
    assert_selector ".chat-sidebar .conversation-row", minimum: 30
    find(".chat-sidebar").scroll_to(:bottom)

    assert_selector ".chat-sidebar #nav_title_conversation_#{talks.last.id}", text: "Talk 30"
    click_on "Talk 30"
    assert_current_path conversation_path(talks.last)
  end

  test "arrow keys, Home and End move along the list" do
    first, second, third = 3.times.map { |index| conversation("Talk #{index}", last_message_at: index.minutes.ago) }

    visit bot_conversations_path(@bot)
    find("#nav_title_conversation_#{first.id}").send_keys(:down)
    assert_focused second
    page.active_element.send_keys(:down, :down)
    assert_focused third
    page.active_element.send_keys(:up)
    assert_focused second
    page.active_element.send_keys(:home)
    assert_focused first
    page.active_element.send_keys(:end)
    assert_focused third
    page.active_element.send_keys(:enter)
    assert_current_path conversation_path(third)
  end

  test "the branch marker leads to the tree, and a node jumps to its conversation" do
    root = conversation("Plan a trip")
    root.messages.create!(entry_key: "1", entry_id: 1, role: "user", content: "Where should I go?")
    root.messages.create!(entry_key: "2", entry_id: 2, role: "assistant", content: "Lisbon.")
    branch = @bot.conversations.create!(user: @bot.user, request_id: "b", durable_id: "b", title: "Lisbon (branch)",
      parent: root, root: root, forked_at_entry_id: 2)

    visit conversation_path(root)
    click_on "1 branch from here"
    assert_selector "h1", text: "Branches"
    assert_selector ".tree__children .tree__meta", text: "after: Lisbon."

    click_on "Lisbon (branch)"
    assert_current_path conversation_path(branch)
    click_on "See all branches"
    assert_selector ".tree__title[aria-current=page]", text: "Lisbon (branch)"
  end

  private
    def conversation(title, **attributes)
      @count = @count.to_i + 1
      @bot.conversations.create!(user: @bot.user, request_id: "r-#{@count}", durable_id: "d-#{@count}", title: title, **attributes)
    end

    def assert_focused(conversation)
      assert_equal "nav_title_conversation_#{conversation.id}", page.evaluate_script("document.activeElement.id")
    end
end
