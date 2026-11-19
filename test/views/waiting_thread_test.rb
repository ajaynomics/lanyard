require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# A busy thread with a card waiting on the person: the card is named just
# above the box, steers say when one holds them (a question does, an
# approval doesn't), and someone else's queued messages are a line each, so
# the queue never buries the card.
class WaitingThreadTest < ActionView::TestCase
  include AgentTestHelper

  setup do
    @agent = create_user.agents.sole
    @conversation = create_conversation(@agent)
    @agent.notes.remember("old", "x")
    payload = invocation_payload(@conversation, tool: "forget_note", arguments: { "key" => "old" })
    Invocation.receive(@conversation, task_id: 7, call_id: "toolu_1", tool: "forget_note", arguments: { "key" => "old" }, digest: payload[:digest])
    @card = @conversation.invocations.sole
  end

  test "the bar above the box names the waiting card and links to its own page, which answers it" do
    html = Nokogiri::HTML5.fragment(render(partial: "conversations/needs_you", locals: { conversation: @conversation }))

    assert_equal approval_path(@card), html.at(".needs-you__card")["href"]
    assert_equal "Needs you · Allow forget note?", html.at(".needs-you__card").text.squish
    assert_empty html.css(".needs-you form, .needs-you button"), "no shortened answer here: the card's page has every choice"

    @card.deny!(by: @agent.user)
    bar = Nokogiri::HTML5.fragment(render(partial: "conversations/needs_you", locals: { conversation: @conversation }))
    assert_empty bar.at(".needs-you").element_children
  end

  test "someone else's queued message is one line that opens to its controls; the person's own is whole, with all of them" do
    question = @conversation.invocations.create!(task_id: "7", call_id: "toolu_q", tool_name: "ask_person", arguments: { "question" => "Tea?" },
      digest: "q", state: "awaiting_person", expires_at: 1.hour.from_now)
    mail = Conversation.received("Can you move the train?\nIt leaves at nine.", from: "Maya in Trips", via: "Campfire", answer: "Reply in the room.", steered: true)
    html = Nokogiri::HTML5.fragment(render(partial: "conversations/queued", locals: { conversation: @conversation, items: [
      { "id" => "31", "mode" => "steer", "text" => mail, "pictures" => 0 },
      { "id" => "32", "mode" => "steer", "text" => "Rome, not Paris", "pictures" => 0 },
      { "id" => "33", "mode" => "followUp", "text" => "And book dinner", "pictures" => 0 }
    ] }))
    other, own, queued = html.css(".message--queued")

    assert_equal "Maya in Trips · Campfire · Can you move the train?", other.at("details#queued_31:not([open]) > summary").text.strip
    assert_includes other.at("details").text, "It leaves at nine."
    assert_equal [ "Queue instead", "Move down" ], controls(other.at("details"))

    assert_nil own.at("details")
    assert_equal "You · Steering · #{@agent} reads this after you answer the card above", own.at(".message__queued-state").text.squish
    assert_equal "Rome, not Paris", own.at(".ui-bubble").text.strip
    assert_equal [ "Queue instead", "Send now", "Move up", "Move down", "Edit", "Withdraw" ], controls(own)
    assert_equal "You · Queued · #{@agent} reads this when it finishes", queued.at(".message__queued-state").text.squish
    assert_equal [ "Steer instead", "Send now", "Move up", "Edit", "Withdraw" ], controls(queued)

    # The approval alone holds no steer: with one waiting, its call hands the card back (Invocation#hands_back?).
    question.update!(state: :succeeded)
    after = render(partial: "conversations/queued", locals: { conversation: @conversation, items: [ { "id" => "32", "mode" => "steer", "text" => "Rome, not Paris", "pictures" => 0 } ] })
    assert_equal "You · Steering · #{@agent} reads this after its current step", Nokogiri::HTML5.fragment(after).at(".message__queued-state").text.squish
    assert_equal [ "Queue instead", "Edit", "Withdraw" ], controls(Nokogiri::HTML5.fragment(after)), "alone, nothing to send sooner or move"
  end

  private
    def controls(html) = html.css(".message__queued-actions button").map { it["aria-label"] || it.text.strip }
end
