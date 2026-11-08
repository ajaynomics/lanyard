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
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: the test reads the person it signed in
    @agent.prompts.create!(name: "review", description: "Review some code", body: "Review $1 carefully")
    @agent.skills.create!(name: "trip", description: "Plans trips.", body: "Ask where first.")
    @conversation = create_conversation(@agent, durable_id: "20")
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

    box.send_keys("t")
    assert_equal [ "/thinking <level>", "/skill:trip" ], visible_options
    assert_equal find("#command_menu [role=option]", text: "/thinking")[:id], box[:"aria-activedescendant"]
    box.send_keys(:down)
    assert_selector "#command_menu [aria-selected=true]", text: "/skill:trip"
    assert_equal find("#command_menu [aria-selected=true]")[:id], box[:"aria-activedescendant"]
    box.send_keys(:tab)
    assert_equal "/skill:trip ", box.value
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
      assert_text "/model <model>"
      assert_text "Choose the model for this agent"
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

  test "/stop stops the reply, and there is no /name: an agent's name is fixed" do
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

    find("#composer textarea").send_keys("/na")
    assert_no_selector "#command_menu [role=option]", text: "/name"
    assert_empty @sent
  end

  test "/compact asks for a summary, with what to keep; /export downloads the history" do
    compacted = Queue.new
    stub_request(:post, "#{SIDECAR}/v1/conversations/20/compactions").with { compacted << JSON.parse(it.body) }
      .to_return(status: 202, body: { id: 1 }.to_json)
    visit conversation_path(@conversation)

    find("#composer textarea").send_keys("/compact keep the dates", :enter)
    assert_equal "keep the dates", compacted.pop(timeout: Capybara.default_max_wait_time)["instructions"]
    assert_selector "form#command_export[action='#{conversation_export_path(@conversation, format: :jsonl)}'][data-turbo=false]", visible: :all
    assert_empty @sent
  end

  test "/branch and /tree are gone: one thread is one agent" do
    visit conversation_path(@conversation)
    find("#composer textarea").send_keys("/")
    assert_selector "#command_menu [role=option]", text: "/new"
    assert_no_selector "#command_menu [role=option]", text: %r{\A/(branch|tree)\b}
    assert_no_selector "#command_branch, #command_tree", visible: :all
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
