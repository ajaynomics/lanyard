require "application_system_test_case"
require_relative "../test_helpers/agent_test_helper"

# A real browser against Falcon. The sidecar is stubbed at Rails' HTTP client
# (WebMock, in this process); the sidecar's own suite runs the real runtime.
class AgentConversationTest < ApplicationSystemTestCase
  include AgentTestHelper

  setup do
    install_agent_adapters
    @conversation = alice_in.conversations.create!(request_id: "r", durable_id: "12")
  end
  teardown { remove_agent_adapters }

  test "the page replaces its whole snapshot as the conversation moves on" do
    question = { id: "question:4:tool:1", kind: "question",
      questions: [ { question: "Which?", description: "", multiple: true, allowCustom: true,
                     options: [ { value: "one", label: "One" }, { value: "two", label: "Two" } ] } ] }
    snapshot(status: "waiting", entries: [ { id: "e1", role: "user", content: "fixture greeting" } ], pending: [ question ])

    visit "/workspaces/one/agent/conversations/#{@conversation.id}"
    assert_text "Which?"
    assert_selector ".agent-question input[type=checkbox]", count: 2

    snapshot(status: "done", entries: [ { id: "e1", role: "user", content: "fixture greeting" },
                                        { id: "e2", role: "assistant", content: "scripted greeting" } ])

    assert_text "scripted greeting"
    assert_no_text "Which?"
    assert_selector ".agent-entry", count: 2
    assert_selector "#agent_status", text: "done"
  end

  private
    def snapshot(status:, entries:, pending: [])
      WebMock.reset!
      stub_request(:get, "#{SIDECAR}/v1/conversations/12?actorId=alice&workspaceId=one")
        .to_return(status: 200, body: { id: 12, status: status, entries: entries, pendingInputs: pending, usage: nil }.to_json)
    end
end
