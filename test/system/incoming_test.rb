require "application_system_test_case"
require_relative "../test_helpers/agent_test_helper"

# What reaches an agent through a channel (Conversation#receive) is someone
# else's message: it shows as theirs, on the agent's side, with no note to the
# model and nothing to edit, and the person's own messages stay theirs.
class IncomingTest < ApplicationSystemTestCase
  include AgentTestHelper

  setup do
    install_sidecar_settings
    mock_ajent_auth
    visit "/auth/ajent/callback"
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: the test reads the person it signed in
    @conversation = create_conversation(@agent)
    entries = [
      [ "Concourse mail", "maya/ajent, task 7f3c", "Can Iris book Thursday?", false, "To answer, use concourse_reply." ],
      [ "Email", "Sam <sam@example.com>", "The invoice is attached.", false, "To reply, use send_email." ],
      [ "Campfire", "Robin in All Talk", "Iris, lunch at noon?", false, "To answer, use campfire_say with room 3." ],
      [ "Routine", "your schedule (0 9 * * 1)", "Plan the week.", true, "Do what it asks." ]
    ].each_with_index.map do |(via, from, text, trusted, answer), index|
      { id: (index + 1).to_s, entryId: index + 1, role: "user", content: Conversation.received(text, from: from, via: via, answer: answer, trusted: trusted) }
    end
    entries << { id: "5", entryId: 5, role: "user", content: "And from me." }
    stub_request(:get, "#{SIDECAR}/v1/conversations/12").with(query: hash_including({})).to_return(body: { status: "idle", failure: nil, pendingInputs: [] }.to_json)
    stub_request(:get, "#{SIDECAR}/v1/conversations/12/entries").with(query: hash_including({}))
      .to_return(body: { entries: entries, cursor: 5, more: false }.to_json)
  end
  teardown do
    remove_sidecar_settings
    OmniAuth.config.mock_auth[:ajent] = nil
  end

  test "a channel's message shows as from its sender, its words only; a routine's is not marked as from someone else" do
    visit conversation_path(@conversation)

    incoming = all(".ui-message[data-role=incoming]", minimum: 4)
    assert_equal [ "maya/ajent · Concourse", "Sam <sam@example.com> · Email", "Robin in All Talk · Campfire", "Routine" ],
      incoming.map { it.find(".ui-incoming__from > span:first-child").text }
    assert_equal [ "Can Iris book Thursday?", "The invoice is attached.", "Iris, lunch at noon?", "Plan the week." ], incoming.map { it.find(".ui-bubble").text }
    assert_equal [ true, true, true, false ], incoming.map { it.has_css?(".ui-incoming__untrusted", text: "Not from you", wait: 0) }
    assert incoming.all? { it[:"data-align"] == "start" && it.has_no_css?(".ui-bubble[data-variant=primary], .message__actions", wait: 0) }
    assert_no_text "Untrusted:"
    assert_no_text "concourse_reply"

    assert_selector ".ui-message[data-role=user][data-align=end] .ui-bubble[data-variant=primary]", count: 1, text: "And from me."
  end
end
