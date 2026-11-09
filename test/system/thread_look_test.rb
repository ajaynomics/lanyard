require "application_system_test_case"
require_relative "../test_helpers/agent_test_helper"

# What makes the thread read as Messages and the app feel like a Mac's
# (docs/design.md): clean copying, a bubble's actions on a tap, the keys.
class ThreadLookTest < ApplicationSystemTestCase
  include AgentTestHelper

  setup do
    install_sidecar_settings
    mock_ajent_auth
    visit "/auth/ajent/callback"
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: the test reads the person it signed in
    @conversation = create_conversation(@agent, durable_id: "20")
    stub_request(:get, "#{SIDECAR}/v1/conversations/20").with(query: hash_including({}))
      .to_return(body: { status: "idle", failure: nil, pendingInputs: [] }.to_json)
    stub_request(:get, "#{SIDECAR}/v1/conversations/20/entries").with(query: hash_including({}))
      .to_return(body: { entries: [
        { id: "1", entryId: 1, role: "user", content: "Help me choose a drink" },
        { id: "2", entryId: 2, role: "assistant", content: "**Tea**, I think.\n\n```ruby\nbrew(:tea)\n```" }
      ], cursor: 2, more: false }.to_json)
  end
  teardown do
    remove_sidecar_settings
    OmniAuth.config.mock_auth[:ajent] = nil
  end

  test "copying across bubbles gives the words alone: no buttons, times or bubble colours" do
    visit conversation_path(@conversation)
    assert_selector ".ui-bubble", text: "Tea"

    text, html = page.evaluate_script(<<~JS)
      (() => {
        const range = document.createRange()
        range.selectNodeContents(document.getElementById("messages"))
        getSelection().removeAllRanges()
        getSelection().addRange(range)
        const copy = new ClipboardEvent("copy", { clipboardData: new DataTransfer(), bubbles: true, cancelable: true })
        document.querySelector("#messages .ui-bubble").dispatchEvent(copy)
        return [ copy.clipboardData.getData("text/plain"), copy.clipboardData.getData("text/html") ]
      })()
    JS

    assert_match(/\AHelp me choose a drink\n+Tea, I think\.\n+brew\(:tea\)\z/, text)
    assert_match "<strong>Tea</strong>", html
    assert_no_match(/Copy|New agent|Today|Just now|November|style=|class=/, text + html)
  end

  test "a tap on a reply shows its actions, and a tap elsewhere hides them; a sent message has none to edit it" do
    visit conversation_path(@conversation)
    mine = find("#messages > [data-role=user]")
    reply = find("#messages > [data-role=assistant]")
    assert_no_link "New agent from here"

    reply.find(".ui-bubble").click
    assert_link "New agent from here", href: new_agent_path(from: @conversation.messages.find_by!(entry_id: 2).id)
    mine.find(".ui-bubble").click
    assert_no_link "New agent from here"
    assert_no_button "Edit"
    assert_no_selector "#messages [data-role=user] .message__actions"
  end

  test "⌘ keys: the help, the search, and an agent by its place in the list" do
    other = @agent.user.agents.create!(name: "Researcher", instructions: "Research.", model: @agent.model)
    create_conversation(other, durable_id: "21").update!(last_message_at: 1.minute.from_now, listed_at: 1.minute.from_now)
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/21}).to_return(body: { status: "idle", entries: [], cursor: nil, more: false }.to_json)
    visit conversation_path(@conversation)

    find("#composer textarea").send_keys([ :control, "/" ])
    assert_selector "dialog#help_dialog[open]", text: "Search agents"
    find("dialog#help_dialog").send_keys(:escape)

    find("#composer textarea").send_keys([ :control, "f" ])
    assert_equal "sidebar_search", page.evaluate_script("document.activeElement.id")

    find("#sidebar_search").send_keys([ :control, "1" ])
    assert_selector ".chat__title", text: "Researcher"
  end
end
