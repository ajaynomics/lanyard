require "test_helper"
require_relative "../test_helpers/agent_test_helper"

class MessageTest < ActiveSupport::TestCase
  include AgentTestHelper

  test "the person's canvas edits that went with a message are the agent's to read, not the bubble's" do
    conversation = create_conversation(create_user(name: "Sam").agents.sole)
    changes = Document.changes_for_agent([], room: 1_000)
    message = conversation.messages.create!(entry_key: "1", entry_id: 1, role: "user", content: "Tidied it up.#{changes}")

    assert_equal "Tidied it up.", message.said
    assert_equal "Tidied it up.", message.typed
    assert message.document_changes?
    assert_not conversation.messages.create!(entry_key: "2", entry_id: 2, role: "user", content: "Thanks").document_changes?
  end
end
