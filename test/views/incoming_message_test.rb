require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# A peer agent's mail looks the same while it waits in the queue as once it
# is in the thread: one partial (messages/_incoming_body), Markdown rendered.
class IncomingMessageTest < ActionView::TestCase
  include AgentTestHelper

  MARKDOWN = "## Plan\n\n- **Book** the hotel\n- See https://example.com/trip\n\n<script>alert(1)</script>".freeze

  setup do
    @conversation = create_conversation(create_user.agents.sole)
  end

  test "a queued peer message renders exactly as the same message in the thread, its Markdown as HTML" do
    content = Conversation.received(MARKDOWN, from: "maya/ajent, task t-1", via: "Concourse mail", answer: "Reply with concourse_reply.")

    render partial: "conversations/queued", locals: { conversation: @conversation, items: [ { "id" => "31", "mode" => "followUp", "text" => content, "pictures" => 0 } ] }
    queued = body_of(rendered)
    render partial: "messages/message", locals: { message: @conversation.messages.create!(entry_key: "1", entry_id: 1, role: "user", content: content) }
    direct = body_of(rendered)

    assert_equal direct, queued
    html = Nokogiri::HTML5.fragment(direct)
    assert_equal "Plan", html.at("h2")&.text
    assert_equal "Book", html.at("li strong")&.text
    assert_equal "https://example.com/trip", html.at("li a")&.[]("href")
    assert_no_match "**", direct
    assert_nil html.at("script"), "raw HTML is dropped"
  end

  test "an email stays as it was typed: its asterisks are words, not formatting" do
    content = Conversation.received("Prices:\n* one\n* two", from: "sam@example.com", via: "Email", answer: "Reply by email.")
    render partial: "messages/message", locals: { message: @conversation.messages.create!(entry_key: "1", entry_id: 1, role: "user", content: content) }
    assert_match "* one", body_of(rendered)
    assert_nil Nokogiri::HTML5.fragment(rendered).at("li")
  end

  private
    def body_of(html) = Nokogiri::HTML5.fragment(html).at(".ui-bubble").to_html
end
