require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/query_count_helper"

# An agent's thread grows for as long as the agent lives: the page shows its
# newest turns, and earlier ones load a page at a time as the person scrolls up.
class Conversations::MessagesControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include QueryCountHelper

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: test reads the person it signed in
    @conversation = create_conversation(@agent)
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/\d+/entries}).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/\d+(\?.*)?\z}).to_return(body: { status: "idle" }.to_json)
  end
  teardown { remove_sidecar_settings }

  test "the thread shows its newest turns; earlier pages load above it until the start, each message once" do
    say(@conversation, rounds: 30) # 90 turns and 30 tool results: three pages

    get conversation_path(@conversation)
    shown = entry_ids
    assert_equal Conversation::Page::SIZE, shown.size
    frame = css_select("turbo-frame.chat__earlier").sole
    assert_equal "lazy", frame["loading"]
    assert_select frame, ".ui-skeleton[aria-label='Loading earlier messages']"

    pages = 1
    while frame
      get frame["data-src"]
      assert_response :ok
      assert_select "turbo-frame##{frame['id']}"
      shown += entry_ids
      pages += 1
      frame = css_select("turbo-frame##{frame['id']} > turbo-frame.chat__earlier").first
    end

    assert_equal 3, pages
    # A tool's result shows inside its call's reply, not as a message of its own.
    assert_equal @conversation.messages.shown.where.not(role: "toolResult").pluck(:entry_id).sort, shown.sort
  end

  test "a page never parts a tool call from its result" do
    say(@conversation, rounds: 30)

    get conversation_path(@conversation)
    assert_every_call_ran
    get css_select("turbo-frame.chat__earlier").sole["data-src"]
    assert_every_call_ran
  end

  test "an earlier page shows a call Rails ran, and one it ran inside another, from its own partial" do
    say(@conversation, rounds: 30)
    first, second = "call_#{@conversation.id}_0", "call_#{@conversation.id}_1"
    @conversation.invocations.create!(task_id: "7", call_id: first, tool_name: "bash", arguments: { "command" => "ls" }, digest: "d", state: "succeeded")
    @conversation.invocations.create!(task_id: "7", call_id: "#{second}/1", tool_name: "remember_note", arguments: {}, digest: "e", state: "succeeded")

    get conversation_path(@conversation)
    frame = css_select("turbo-frame.chat__earlier").sole
    while frame
      get frame["data-src"]
      assert_response :ok
      frame = css_select("turbo-frame##{frame['id']} > turbo-frame.chat__earlier").first
    end
    assert_select "##{Invocation.dom_target(first)}"
    assert_select "##{Invocation.dom_target(second)}_calls ##{Invocation.dom_target("#{second}/1")}"
  end

  test "a longer thread costs no more queries" do
    say(@conversation, rounds: 20)
    longer = create_conversation(@agent, durable_id: "13")
    say(longer, rounds: 40)

    baseline = queries_in { get conversation_path(@conversation) }
    assert_same_queries(baseline) { get conversation_path(longer) }

    shorter_page, longer_page = [ @conversation, longer ].map { conversation_messages_path(it, before: it.messages.maximum(:entry_id)) }
    baseline = queries_in { get shorter_page }
    assert_same_queries(baseline) { get longer_page }
  end

  test "another person's thread is not found" do
    theirs = create_conversation(create_user(name: "Mallory").agents.sole, durable_id: "99")
    get conversation_messages_path(theirs, before: 10)
    assert_response :not_found
  end

  private
    # Rounds of a question, a reply that runs a tool, its result and an answer.
    def say(conversation, rounds:)
      rounds.times do |round|
        entry = round * 4
        call = { "id" => "call_#{conversation.id}_#{round}", "name" => "bash", "arguments" => { "command" => "ls" } }
        [ { role: "user", content: "Question #{round}" },
          { role: "assistant", content: "Looking.", tool_calls: [ call ] },
          { role: "toolResult", content: "a.txt", tool_name: "bash", tool_call_id: call["id"] },
          { role: "assistant", content: "Answer #{round}" } ].each.with_index(1) do |message, offset|
          conversation.messages.create!(entry_key: "e#{entry + offset}", entry_id: entry + offset, **message)
        end
      end
    end

    # The composer's template for a message being sent sorts after every entry; it is not one.
    def entry_ids = css_select(".ui-message[data-entry-id]").map { it["data-entry-id"].to_i } - [ 2**53 - 1 ]

    def assert_every_call_ran
      calls = css_select(".tool-call .ui-trace__title").map(&:text)
      assert_operator calls.size, :>=, 13
      assert calls.all? { it == "Ran bash" }, calls.inspect
      assert_select ".ui-message[data-role=tool]", count: 0
    end
end
