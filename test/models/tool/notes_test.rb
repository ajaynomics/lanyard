require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

# An agent adds to a note by reading it and saving it back whole, so reading
# must never hand back less than the note while looking like all of it.
class Tool::NotesTest < ActiveSupport::TestCase
  include AgentTestHelper

  setup do
    @agent = create_user(name: "Alice").agents.sole
    @conversation = create_conversation(@agent)
  end

  test "a long note read by its exact key and saved back keeps every character" do
    body = "Gift ideas — é ✓\n" + (1..5_000).map { (97 + it % 26).chr }.join
    @agent.notes.create!(key: "gift-ideas", body: body)
    @agent.notes.create!(key: "gifts-given", body: "Mentions gift-ideas, so it matches too.")

    notes = use("list_notes", { "query" => "gift-ideas" })[:notes]
    assert_equal %w[ gift-ideas gifts-given ], notes.pluck(:key), "the note named comes first, the other matches after it"
    assert_equal body, notes.first[:body]
    assert_nil notes.first[:cut]

    use("remember_note", { "key" => "gift-ideas", "body" => notes.first[:body] + "\nA scarf" }, call_id: "toolu_2")
    assert_equal body + "\nA scarf", @agent.notes.find_by!(key: "gift-ideas").body
  end

  test "in a list, a note over 2,000 characters says it was cut and how long it is; one of 2,000 doesn't" do
    @agent.notes.create!(key: "long", body: "a" * 2_001)
    @agent.notes.create!(key: "full", body: "b" * 2_000)

    notes = use("list_notes", {})[:notes].index_by { it[:key] }
    assert_equal "a" * 2_000, notes["long"][:body]
    assert_equal 2_001, notes["long"][:length]
    assert_equal "Only the first 2000 of 2001 characters. list_notes with its exact key gives it whole.", notes["long"][:cut]
    assert_equal "b" * 2_000, notes["full"][:body]
    assert_equal %i[ key body updatedAt ], notes["full"].keys
  end

  test "words that only partly match a key list previews, still marked cut" do
    @agent.notes.create!(key: "long-plan", body: "c" * 3_000)
    note = use("list_notes", { "query" => "long" })[:notes].sole
    assert_equal 2_000, note[:body].length
    assert note[:cut]
  end

  test "the tools say how to read a note whole, and that saving replaces it" do
    assert_match "pass its exact key to get it whole", @conversation.tool("list_notes").description
    assert_match "read it whole first", @conversation.tool("remember_note").description
  end

  private
    def use(tool, arguments, call_id: "toolu_1")
      payload = invocation_payload(@conversation, tool: tool, arguments: arguments, call_id: call_id)
      Invocation.receive(@conversation, task_id: payload[:taskId], call_id: call_id, tool: tool,
        arguments: arguments, digest: payload[:digest]).deep_symbolize_keys.fetch(:result)
    end
end
