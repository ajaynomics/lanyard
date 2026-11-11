require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/concourse_test_helper"

# The line above the composer (Conversation::StatusLine, conversations/_status_line):
# quiet facts always, colour only for what needs the person.
class Conversation::StatusLineTest < ActiveSupport::TestCase
  include AgentTestHelper, ConcourseTestHelper

  setup do
    install_sidecar_settings
    @agent = create_user.agents.sole
    @agent.update!(model: "anthropic/claude-sonnet-5-5", thinking_level: "high")
    @conversation = create_conversation(@agent)
    stub_request(:get, "#{SIDECAR}/v1/models").to_return(body: { models: [
      { id: @agent.model, name: "Claude Sonnet 5.5", thinkingLevels: %w[ medium high ], images: true, contextWindow: 200_000, compactAt: 160_000 } ] }.to_json)
  end
  teardown { remove_sidecar_settings }

  test "quiet: the model and effort, a subscription's plan, the room used, and nothing in colour" do
    reply(tokens: 84_000)
    @conversation.update!(usage: { "input" => 48_000, "cacheRead" => 1_100_000, "cacheWrite" => 92_000, "output" => 18_000, "cost" => 2.14 })

    summary = html.at_css(".status-line__summary")
    assert_equal [ "Sonnet 5.5 · High effort", "Included in plan" ], summary.css("> span:not([role])").map { it.text.squish }.first(2)
    assert_equal "Context 42% full", summary.at_css("[role=img]")["aria-label"]
    assert_nil summary.at_css(".status-line__attention, [data-nearly-full], .status-line__concourse")

    details = html.at_css(".status-line__panel").text.squish
    assert_includes details, "Using Claude Sonnet 5.5, high effort · Change"
    assert_includes details, "Cost Included in plan (would be $2.14 at API prices)"
    assert_includes details, "Room used 42% · 84k of 200k tokens"
    assert_includes details, "Read 1.24M tokens · 1.1M from cache, 92k newly cached, 48k new"
    assert_includes details, "Written 18k tokens"
    assert_includes details, "89% served from cache"
  end

  test "an API key's agent says what the thread has cost; nearly at the summary point, it says so" do
    @agent.update_column(:model, "anthropic-api/claude-sonnet-5-5") # an install that allows the API key
    stub_request(:get, "#{SIDECAR}/v1/models").to_return(body: { models: [
      { id: @agent.model, name: "Claude Sonnet 5.5", thinkingLevels: %w[ high ], images: true, contextWindow: 200_000, compactAt: 160_000 } ] }.to_json)
    reply(tokens: 140_000)
    @conversation.update!(usage: { "input" => 140_000, "output" => 900, "cost" => 2.14 })

    summary = html.at_css(".status-line__summary")
    assert_includes summary.text, "$2.14 this thread"
    assert summary.at_css("[data-nearly-full]")
    assert_equal "Getting full: summarises soon", summary.at_css(".status-line__attention").text
    assert Conversation::StatusLine.new(@conversation).attention?
  end

  test "Concourse: connected quietly, red when mail can't arrive, with the day's mail and open tasks in Details" do
    concourse = create_concourse_agent(@agent, checked_at: 1.minute.ago, push_token: "push")
    Conversation.received("Can you check Thursday?", from: "acme/robin", via: "Concourse mail", answer: "Reply with concourse_reply.").then do
      @conversation.messages.create!(entry_key: "m", entry_id: 1, role: "user", content: it, created_at: 4.minutes.ago)
    end
    @conversation.peer_tasks.create!(task_id: "t1", peer: "acme/sam", direction: "outbound", state: "TASK_STATE_WORKING")
    @conversation.peer_tasks.create!(task_id: "t2", peer: "acme/sam", direction: "outbound", state: "TASK_STATE_COMPLETED")

    link = html.at_css(".status-line__concourse")
    assert_equal [ "Concourse connected", "ok" ], [ link.text, link["data-state"] ]
    details = html.at_css(".status-line__panel").text.squish
    assert_includes details, "Address acme/assistant in acme"
    assert_includes details, "Delivery Instant (push on) · last mail 4 minutes ago"
    assert_includes details, "Today 1 message in · 1 open task waiting on others"

    streams = capture_turbo_stream_broadcasts(@conversation) { concourse.update!(status: "disconnected") }
    assert_equal %W[ status_summary_conversation_#{@conversation.id} status_details_conversation_#{@conversation.id} ], streams.map { it["target"] }
    link = html.at_css(".status-line__concourse")
    assert_equal [ "Concourse offline: mail can't arrive", "trouble" ], [ link.text, link["data-state"] ]

    assert_empty capture_turbo_stream_broadcasts(@conversation) { concourse.update!(cursor: "c-2") }, "reading further back changes nothing shown"
  end

  test "on two networks the line speaks for one in trouble, by name, and Details lists each" do
    create_concourse_agent(@agent, checked_at: 1.minute.ago, push_token: "push")
    second = create_second_network(@agent, checked_at: 1.minute.ago)
    assert_equal [ "Concourse connected", "ok" ], html.at_css(".status-line__concourse").then { [ it.text, it["data-state"] ] }

    second.update!(status: "declined")
    link = html.at_css(".status-line__concourse")
    assert_equal [ "Concourse declined this agent in example", "trouble" ], [ link.text, link["data-state"] ]
    details = html.at_css(".status-line__panel").text.squish
    assert_includes details, "Address acme/assistant in acme Delivery Instant (push on)"
    assert_includes details, "Address example/assistant in example Delivery Concourse declined this agent"

    @conversation.peer_tasks.create!(task_id: "t1", peer: "example/sam", direction: "inbound", state: "TASK_STATE_WORKING", concourse_agent: second)
    assert_includes html.at_css(".status-line__panel").text.squish, "1 open task waiting on this agent"
    second.destroy!
    @conversation = Conversation.find(@conversation.id) # as the next page would load it
    assert_includes html.at_css(".status-line__panel").text.squish, "no open tasks", "a task from a network it left closes with it"
  end

  test "changing the model or effort redraws the line, and the end of a run replaces its parts, not the open panel" do
    streams = capture_turbo_stream_broadcasts(@conversation) { @agent.update!(thinking_level: "medium") }
    assert_includes streams.first.to_html, "Sonnet 5.5 · Medium effort"
    assert(streams.none? { it["target"].include?("status_line") })
  end

  private
    def reply(tokens:)
      @conversation.messages.create!(entry_key: "r", entry_id: 2, role: "assistant", content: "Hi", usage: { "totalTokens" => tokens, "model" => @agent.model })
    end

    def html = Nokogiri::HTML.fragment(ApplicationController.render(partial: "conversations/status_line", locals: { conversation: @conversation }))
end
