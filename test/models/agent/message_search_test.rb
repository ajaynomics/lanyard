require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

class Agent::MessageSearchTest < ActiveSupport::TestCase
  include AgentTestHelper

  setup do
    owner = create_user
    @agent = owner.start_agent("Searched")
    @other = owner.start_agent("Other")
  end

  test "it reads one agent's words, its branches' included, in any case, but not a tool's output" do
    thread = @agent.conversation
    branch = @agent.conversations.create!(parent: thread, root: thread, request_id: "branch")
    thread.messages.create!(entry_id: 1, entry_key: "1", role: "user", content: "Pastéis de nata")
    thread.messages.create!(entry_id: 2, entry_key: "2", role: "toolResult", content: "pastéis.txt")
    branch.messages.create!(entry_id: 3, entry_key: "3", role: "assistant", content: "PASTÉIS in Belém")
    @other.conversation.messages.create!(entry_id: 1, entry_key: "1", role: "user", content: "pastéis elsewhere")

    search = Agent::MessageSearch.new(@agent, " pastéis ")
    assert_equal [ branch.id, thread.id ], search.conversation_ids
    assert_nil search.older
  end

  test "a match older than one batch is found on the second page" do
    thread = @agent.conversation
    thread.messages.create!(entry_id: 1, entry_key: "old", role: "user", content: "The rare word")
    Message.insert_all!((1..Agent::MessageSearch::BATCH).map do |index|
      { conversation_id: thread.id, entry_id: 1 + index, entry_key: "new-#{index}", role: "user", content: "Routine" }
    end)

    first = Agent::MessageSearch.new(@agent, "rare")
    assert_empty first.conversation_ids
    assert first.older

    second = Agent::MessageSearch.new(@agent, "rare", before: first.older.to_s)
    assert_equal [ thread.id ], second.conversation_ids
    assert_nil second.older
  end
end
