require "application_system_test_case"
require_relative "../test_helpers/agent_test_helper"

# Finding, archiving and moving along agents, each one thread, in a real browser.
class ConversationListTest < ApplicationSystemTestCase
  include AgentTestHelper

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    # Each row here is an agent the test makes, not the starter.
    @user = User.find_by!(oidc_sub: "42") # tenancy-ok: the test reads the person it signed in
    @user.made_agents.destroy_all
    # Every conversation page load asks the sidecar for news; there is none.
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/[^/]+/entries}).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/[^/?]+(\?.*)?\z}).to_return(body: { status: "idle" }.to_json)
  end
  teardown do
    remove_sidecar_settings
    OmniAuth.config.mock_auth[:ajent] = nil
  end

  test "search finds an agent by the words in its messages, once it is chosen" do
    conversation("Weekend").messages.create!(entry_key: "1", entry_id: 1, role: "assistant", content: "Try the pastéis in Belém")
    conversation("Groceries")

    visit conversations_path
    assert_selector ".conversation-row", count: 2
    find("body").send_keys("/")
    assert_equal "q", page.evaluate_script("document.activeElement.name")
    find("summary[aria-label='Sort and filter']").click
    select "Weekend", from: "Search in"
    assert_selector ".conversation-row", count: 1
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

  test "typing filters both Agents views without moving focus from search" do
    lead = conversation("Juniper Lead").agent
    report = conversation("Saffron Analyst").agent
    report.update!(parent_id: lead.id)
    other = Workspace.make(name: "Cedar Studio", owner: @user)
    @user.start_agent("Cedar Lead", workspace: other)

    %w[ chart list ].each do |lens|
      visit conversations_path(lens:)
      assert_selector "#conversations .conversation-row__name", count: 3
      find_field("Search agents").send_keys("Saffron")

      assert_selector "#conversations .conversation-row__name", count: 1, text: "Saffron Analyst"
      assert_no_selector "#conversations .conversation-row__name", text: /Juniper Lead|Cedar Lead/, visible: :all
      assert_selector "input[name=q]:focus"
      assert_selector ".agent-lenses [aria-current=page]", text: lens.capitalize
      assert_equal "Saffron", Rack::Utils.parse_query(URI(current_url).query)["q"]

      assert_selector "#agent_results[complete]:not([busy])", visible: :all
      wait_for_settled_turbo
      find_field("Search agents").send_keys([ :control, "a" ], :backspace)
      assert_field "Search agents", with: ""
      assert_selector "#conversations .conversation-row__name", count: 3
      assert_selector "input[name=q]:focus"
    end
  end

  test "archiving hides an agent from the sidebar, and unarchiving brings it back" do
    other = conversation("Other")
    talk = conversation("Talk")

    visit conversation_path(other)
    assert_selector ".chat-sidebar .conversation-row__link", text: "Talk"
    # The live list can redraw a row until its stream is connected; a click then lands on the old one.
    assert_no_selector "turbo-cable-stream-source:not([connected])", visible: :all
    click_on "Talk"
    # The title can show before Talk's visit can take the menu click.
    assert_current_path conversation_path(talk)
    assert_selector ".chat__title", text: "Talk"
    wait_for_settled_turbo
    find(".chat__more").click
    within("#chat_actions:popover-open") { click_on "Archive agent" }

    # Wait for the archive response before using the morphed menu.
    assert_no_selector ".chat-sidebar .conversation-row__link", text: "Talk"
    wait_for_settled_turbo
    within("#chat_actions:popover-open") { assert_button "Unarchive agent" }
    assert talk.reload.archived?

    within("#chat_actions:popover-open") { click_on "Unarchive agent" }
    assert_selector ".chat-sidebar .conversation-row__link", text: "Talk"
    assert_not talk.reload.archived?

    visit conversations_path
    assert_no_selector "turbo-cable-stream-source:not([connected])", visible: :all
    find("#reporting_actions_agent_#{talk.agent_id}").click
    within("#row_menu_agent_#{talk.agent_id}") { click_button "Archive" }
    assert_no_selector ".conversation-row__link", text: "Talk"
    find("summary[aria-label='Sort and filter']").click
    select "Archived", from: "Show"
    assert_selector ".conversation-row__link", text: "Talk"
  end

  test "the sidebar renders the whole list without a lazy page" do
    talks = 31.times.map { |index| conversation("Talk #{index}", last_message_at: index.minutes.ago, listed_at: index.minutes.ago) }

    visit conversation_path(talks.first)
    assert_selector ".chat-sidebar .conversation-row", count: 31
    assert_no_selector ".chat-sidebar turbo-frame[loading=lazy]", visible: :all
    assert_selector ".chat-sidebar #row_conversation_#{talks.last.id}", text: "Talk 30"
    click_on "Talk 30"
    assert_current_path conversation_path(talks.last)
  end

  test "arrow keys, Home and End move along the list" do
    first, second, third = 3.times.map { |index| conversation("Talk #{index}", last_message_at: index.minutes.ago, listed_at: index.minutes.ago) }

    visit conversations_path
    find("#row_conversation_#{first.id} a").send_keys(:down)
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

  private
    # An agent named `name`, made like the starter, and its thread, admitted.
    def conversation(name, **attributes)
      @count = @count.to_i + 1
      @user.start_agent(name).conversation.tap { it.update_columns(durable_id: "d-#{@count}", **attributes) }
    end

    def assert_focused(conversation)
      assert_selector "#row_conversation_#{conversation.id} a:focus"
    end
end
