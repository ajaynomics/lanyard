require "application_system_test_case"
require_relative "../test_helpers/agent_test_helper"

# The composer's list and commands (PARITY.md §12, §17) in a real browser.
# The sidecar is stubbed at Rails' HTTP client, as in conversation_test.rb.
class CommandsTest < ApplicationSystemTestCase
  include AgentTestHelper

  HISTORY = [ { id: "1", entryId: 1, role: "user", content: "Help me choose a drink" },
              { id: "2", entryId: 2, role: "assistant", content: "**Tea**, I think." } ].freeze

  setup do
    install_sidecar_settings
    mock_ajent_auth
    visit "/auth/ajent/callback"
    @bot = User.find_by!(oidc_sub: "42").bots.sole # tenancy-ok: the test reads the person it signed in
    @bot.prompts.create!(name: "review", description: "Review some code", body: "Review $1 carefully")
    @bot.skills.create!(name: "trip", description: "Plans trips.", body: "Ask where first.")
    @conversation = create_conversation(@bot, durable_id: "20")
    @conversation.update!(title: "Drinks")
    stub_request(:get, "#{SIDECAR}/v1/conversations/20").with(query: hash_including({}))
      .to_return(body: { status: "idle", failure: nil, pendingInputs: [] }.to_json)
    stub_entries(HISTORY)
    @sent = []
    stub_request(:post, "#{SIDECAR}/v1/conversations/20/submissions").with { @sent << JSON.parse(it.body)["content"] }
      .to_return(status: 202, body: { id: 3 }.to_json)
  end
  teardown do
    remove_sidecar_settings
    OmniAuth.config.mock_auth[:ajent] = nil
  end

  test "/ opens the list; the arrows move, Tab completes, Esc closes, and Enter sends what is typed" do
    visit conversation_path(@conversation)
    box = find("#composer textarea")

    box.send_keys("/")
    assert_selector "#command_menu [role=option]", text: "/new"
    assert_selector "#command_menu [role=option]", text: "/review"
    assert_selector "#command_menu [role=option]", text: "/skill:trip"
    assert_equal "true", box[:"aria-expanded"]

    box.send_keys("n")
    assert_equal [ "/new", "/name <name>" ], visible_options
    assert_equal "command_option_0", box[:"aria-activedescendant"]
    box.send_keys(:down)
    assert_selector "#command_menu [aria-selected=true]", text: "/name"
    assert_equal find("#command_menu [aria-selected=true]")[:id], box[:"aria-activedescendant"]
    box.send_keys(:tab)
    assert_equal "/name ", box.value
    assert_no_selector "#command_menu"

    box.fill_in with: ""
    box.send_keys("/th", :tab)
    assert_equal "/thinking ", box.value
    assert_selector "#command_menu [role=option]", text: "Extra high"
    box.send_keys("hi", :tab)
    assert_equal "/thinking high ", box.value

    box.fill_in with: ""
    box.send_keys("/")
    assert_selector "#command_menu"
    box.send_keys(:escape)
    assert_no_selector "#command_menu"
    assert_equal "/", box.value

    # The list is open on /review, but Enter sends the two letters typed.
    box.send_keys(:backspace, "/re")
    assert_selector "#command_menu [aria-selected=true]", text: "/review"
    box.send_keys(:enter)
    assert_selector "#messages > [data-pending]", text: "/re"
    assert_equal "", box.value
    wait_until { @sent.any? }
    assert_equal [ "/re" ], @sent
  end

  test "on a phone, a tap completes; /help lists the commands and the keys" do
    page.current_window.resize_to(390, 800)
    visit conversation_path(@conversation)
    box = find("#composer textarea")

    box.send_keys("/he")
    find("#command_menu [role=option]", text: "/help").click
    assert_equal "/help ", box.value
    assert_equal box, page.active_element
    box.send_keys(:enter)

    within "#help_dialog[open]" do
      assert_text "/name <name>"
      assert_text "Rename this conversation"
      assert_text "/review"
      assert_text "/skill:trip"
      assert_text "Shift + Enter"
      assert_text "In an empty box, bring back your last message"
      click_on "Close"
    end
    assert_no_selector "#help_dialog[open]"
    assert_equal "", box.value
    assert_empty @sent
  ensure
    page.current_window.resize_to(1400, 1400)
  end

  test "/stop stops the reply and /name renames the conversation" do
    cancelled = Queue.new
    stub_request(:post, "#{SIDECAR}/v1/conversations/20/cancellations").with { cancelled << JSON.parse(it.body)["requestId"] }
      .to_return(status: 202, body: {}.to_json)
    visit conversation_path(@conversation)
    box = find("#composer textarea")

    box.send_keys("/stop", :enter)
    sent_with = cancelled.pop(timeout: Capybara.default_max_wait_time)
    assert Agent::Access.valid_id?(sent_with)
    # Back on the page, with a new request id for the next /stop.
    assert_no_selector "#command_stop input[value='#{sent_with}']", visible: :all

    box = find("#composer textarea")
    box.send_keys("/name Tea or coffee", :enter)
    assert_selector ".chat__title", text: "Tea or coffee"
    assert_selector "#rename_form input[value='Tea or coffee']", visible: :all
    assert_equal "Tea or coffee", @conversation.reload.title

    find("#composer textarea").send_keys("/name", :enter)
    assert_selector "#composer_error", text: "Type a name after /name."
    assert_empty @sent
  end

  test "/copy and a reply's Copy button write its Markdown to the clipboard" do
    page.driver.browser.execute_cdp("Browser.grantPermissions", origin: page.server_url, permissions: %w[ clipboardReadWrite clipboardSanitizedWrite ])
    visit conversation_path(@conversation)

    find("#composer textarea").send_keys("/copy", :enter)
    assert_selector "#messages [data-copy-reply]", text: "Copied"
    assert_equal "**Tea**, I think.", page.evaluate_async_script("navigator.clipboard.readText().then(arguments[0])")
    assert_empty @sent
  end

  test "Up in an empty box brings back the last message; a skill comes back as typed and shows as its name" do
    visit conversation_path(@conversation)
    box = find("#composer textarea")

    box.send_keys(:up)
    assert_equal "Help me choose a drink", box.value

    box.fill_in with: ""
    stub_entries(HISTORY + [ { id: "3", entryId: 3, role: "user", content: %(<skill name="trip" location="skill:trip">\nAsk where first.\n</skill>\n\nto Lisbon) } ])
    box.send_keys("/skill:trip to Lisbon", :enter)
    assert_selector "#messages > [data-role=user] .message__skill", text: "Skill: trip"
    assert_no_selector "#messages > [data-pending]"
    wait_until { @sent.any? }
    assert_equal [ %(<skill name="trip" location="skill:trip">\nAsk where first.\n</skill>\n\nto Lisbon) ], @sent

    visit conversation_path(@conversation)
    find("#composer textarea").send_keys(:up)
    assert_equal "/skill:trip to Lisbon", find("#composer textarea").value
  end

  test "a draft survives a reload and clears once sent; signing out forgets it" do
    visit conversation_path(@conversation)
    find("#composer textarea").send_keys("Half a thought")
    refresh
    box = find("#composer textarea")
    assert_equal "Half a thought", box.value

    box.send_keys(:enter)
    assert_selector "#messages > [data-pending]", text: "Half a thought"
    refresh
    assert_equal "", find("#composer textarea").value

    find("#composer textarea").send_keys("Another")
    click_on "Sign out"
    assert_nil page.evaluate_script("localStorage.getItem('draft:#{@conversation.id}')")
  end

  private
    def stub_entries(entries)
      stub_request(:get, "#{SIDECAR}/v1/conversations/20/entries").with(query: hash_including({}))
        .to_return(body: { entries: entries, cursor: entries.last[:entryId], more: false }.to_json)
    end

    def visible_options = all("#command_menu [role=option]").map { it.find(".command-menu__name").text }
end
