require "application_system_test_case"
require_relative "../test_helpers/agent_test_helper"

# What a person is typing survives whatever redraws the page: a message
# streamed in, and a refresh that morphs the page (a connector's change
# refreshes every conversation page; an agent's work refreshes its settings).
class KeepsTypingTest < ApplicationSystemTestCase
  include AgentTestHelper

  setup do
    install_sidecar_settings
    mock_ajent_auth
    visit "/auth/ajent/callback"
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: the test reads the person it signed in
    @conversation = create_conversation(@agent)
    stub_request(:get, "#{SIDECAR}/v1/conversations/12").with(query: hash_including({}))
      .to_return(body: { status: "idle", failure: nil, pendingInputs: [] }.to_json)
    stub_request(:get, "#{SIDECAR}/v1/conversations/12/entries").with(query: hash_including({}))
      .to_return(body: { entries: [ { id: "1", entryId: 1, role: "user", content: "Plan Thursday" } ], cursor: 1, more: false }.to_json)
  end
  teardown do
    remove_sidecar_settings
    OmniAuth.config.mock_auth[:ajent] = nil
  end

  test "a message streamed in and a refresh leave the composer's words, focus and caret as they were" do
    visit conversation_path(@conversation)
    assert_selector ".ui-bubble", text: "Plan Thursday"
    assert_no_selector "turbo-cable-stream-source:not([connected])", visible: :all
    box = find("#composer textarea")
    box.send_keys("Book the room for ten")
    place_caret 9
    counting_morphs

    @conversation.messages.create!(entry_key: "2", entry_id: 2, role: "assistant", content: "Which room?")
    assert_selector ".ui-markdown", text: "Which room?"
    Turbo::StreamsChannel.broadcast_refresh_to @agent.user, :connectors
    wait_until { page.evaluate_script("window.morphs") >= 1 }

    assert_equal "Book the room for ten", find("#composer textarea").value
    assert_equal "content", page.evaluate_script("document.activeElement.name"), "the box keeps focus"
    assert_equal [ 9, 9 ], page.evaluate_script("[ document.activeElement.selectionStart, document.activeElement.selectionEnd ]")
    assert_equal "Book the room for ten", page.evaluate_script("localStorage.getItem('draft:#{@conversation.id}')")
  end

  # The page asks before leaving with changes unsaved; a refresh is not leaving.
  test "a message sent empties the box at once, and a refresh afterwards neither fills it again nor sends it twice" do
    sent = []
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").with { sent << JSON.parse(it.body)["content"] }
      .to_return(status: 202, body: { id: 3 }.to_json)
    visit conversation_path(@conversation)
    assert_no_selector "turbo-cable-stream-source:not([connected])", visible: :all
    find("#composer textarea").send_keys("Book the room", :enter)

    assert_equal "", find("#composer textarea").value
    assert_nil page.evaluate_script("localStorage.getItem('draft:#{@conversation.id}')")
    wait_until { sent.any? }
    counting_morphs

    Turbo::StreamsChannel.broadcast_refresh_to @agent.user, :connectors
    wait_until { page.evaluate_script("window.morphs") >= 1 }

    assert_equal "", find("#composer textarea").value
    assert_equal "content", page.evaluate_script("document.activeElement.name"), "still typing in the box"
    find("#composer textarea").send_keys(:enter, "Thanks", :enter)
    wait_until { sent.include?("Thanks") }
    assert_equal [ "Book the room", "Thanks" ], sent, "the first message went once"
  end

  test "a refresh brings a new saved prompt into the / list, and words typed in a box that lost focus come back" do
    visit conversation_path(@conversation)
    assert_no_selector "turbo-cable-stream-source:not([connected])", visible: :all
    find("#composer textarea").send_keys("Book the room")
    page.execute_script("document.activeElement.blur()")
    counting_morphs

    @agent.prompts.create!(name: "standup", body: "Plan the day")
    Turbo::StreamsChannel.broadcast_refresh_to @agent.user, :connectors
    wait_until { page.evaluate_script("window.morphs") >= 1 }

    assert_selector "#command_menu [role=option][data-name=standup]", visible: :all
    assert_equal "Book the room", find("#composer textarea").value
  end

  test "pictures picked for the next message stay through a refresh" do
    png = Base64.strict_decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")
    file = Rails.root.join("tmp/system-test-dot-#{SecureRandom.hex(4)}.png").tap { it.binwrite(png) }
    visit conversation_path(@conversation)
    assert_no_selector "turbo-cable-stream-source:not([connected])", visible: :all
    find("#composer input[type=file]", visible: false).attach_file(file.to_s)
    assert_selector ".composer__thumb img", count: 1
    counting_morphs

    Turbo::StreamsChannel.broadcast_refresh_to @agent.user, :connectors
    wait_until { page.evaluate_script("window.morphs") >= 1 }

    assert_selector ".composer__thumb img", count: 1
    assert_equal 1, page.evaluate_script("document.querySelector('#composer input[type=file]').files.length")
  ensure
    file&.delete
  end

  test "an agent's work refreshing its settings neither wipes the instructions being typed nor asks to leave" do
    visit agent_instructions_path(@agent)
    assert_no_selector "turbo-cable-stream-source:not([connected])", visible: :all
    box = find("textarea[name='agent[instructions]']")
    box.send_keys(:end, " Always say when.")
    # The refresh tries a visit of this page (Turbo waits a moment first); the form decides what becomes of it.
    page.execute_script("window.refreshes = 0; document.addEventListener('turbo:before-visit', () => window.refreshes++)")

    Turbo::StreamsChannel.broadcast_refresh_to @agent
    wait_until { page.evaluate_script("window.refreshes") >= 1 }

    assert find("textarea[name='agent[instructions]']").value.end_with?(" Always say when."), "the typed words stay"
    assert_equal "agent[instructions]", page.evaluate_script("document.activeElement.name"), "no question takes the focus"
    assert_no_selector "#confirm[open]"

    click_on "Save"
    wait_until { @agent.reload.instructions.end_with?(" Always say when.") }
  end

  # Any other text box keeps its words while typed in, on any page that morphs (application.js).
  test "a connector changing leaves the connector JSON being pasted" do
    visit connectors_path
    assert_no_selector "turbo-cable-stream-source:not([connected])", visible: :all
    find("textarea[name='connector[json]']").send_keys(%({ "mcpServers": {))
    counting_morphs

    Turbo::StreamsChannel.broadcast_refresh_to @agent.user, :connectors
    wait_until { page.evaluate_script("window.morphs") >= 1 }

    assert_equal %({ "mcpServers": {), find("textarea[name='connector[json]']").value
    assert_equal "connector[json]", page.evaluate_script("document.activeElement.name")
  end

  private
    def place_caret(at) = page.execute_script("document.activeElement.setSelectionRange(#{at}, #{at})")

    # A refresh that never came would pass for one that kept the words.
    def counting_morphs = page.execute_script("window.morphs = 0; document.addEventListener('turbo:morph', () => window.morphs++)")
end
