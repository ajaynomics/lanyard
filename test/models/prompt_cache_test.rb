require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# The prompt cache (Message::PromptCache, docs/prompt-cache.md): a reply that
# read back much less than the one before cached is a miss, told with its
# likeliest reason; where the thread ends says how much the cache served and
# how long it stays warm; settings pages warn while it is warm.
class PromptCacheTest < ActiveSupport::TestCase
  include AgentTestHelper

  setup do
    install_sidecar_settings
    @agent = create_user.agents.sole
    @conversation = create_conversation(@agent)
    @start = Time.zone.parse("2026-11-09 10:00")
    @entry = 0
  end
  teardown { remove_sidecar_settings }

  test "a reply that reads back what the one before cached is a hit" do
    reply(write: 20_000)
    second = reply(read: 20_000, write: 400, at: 1.minute)

    assert_nil second.cache_miss
    assert_in_delta 0.98, second.cache_hit_rate, 0.01
  end

  test "after the cache lapses, a reply misses, and says how long it had been and how long the cache keeps" do
    reply(write: 20_000)
    late = reply(input: 20_400, at: 70.minutes)

    assert_equal({ "tokens" => 20_400, "reason" => "idle", "idle" => 4_200, "ttl" => 3_600, "before" => 20_003 }, late.cache_miss,
      "the count is this reply's own words not read from the cache")
    assert_equal "Cache missed: 20k tokens read again in full, after about 1 hour idle (the cache keeps an hour).",
      helper.cache_miss_line(late)
    assert_includes render_message(late), "Cache missed: 20k tokens read again in full, after about 1 hour idle"
  end

  test "Anthropic's cache is kept an hour; another provider's lasts its few minutes" do
    claude = reply(write: 20_000)
    assert_equal 1.hour, claude.cache_ttl
    assert_nil reply(read: 20_000, write: 400, at: 40.minutes).cache_miss, "40 minutes on, an hour's cache still serves"

    gpt = reply(write: 30_000, at: 41.minutes, model: "openai/gpt-5.5")
    assert_equal 5.minutes, gpt.cache_ttl
    late = reply(input: 30_400, at: 53.minutes, model: "openai/gpt-5.5")
    assert_equal "Cache missed: 30k tokens read again in full, after 12 minutes idle (the cache keeps 5 minutes).", helper.cache_miss_line(late)
  end

  test "a miss soon after says why: what the agent reads first changed, a summary, or another model" do
    reply(write: 20_000)
    assert_equal "changed", reply(read: 3_000, write: 17_400, at: 1.minute).cache_miss["reason"]

    @conversation.messages.create!(entry_key: "summary", entry_id: @entry += 1, role: "summary", content: "<summary>\nx\n</summary>")
    assert_equal "summary", reply(write: 6_000, at: 2.minutes).cache_miss["reason"]

    assert_equal "model", reply(write: 6_400, at: 3.minutes, model: "anthropic/claude-haiku-5-5").cache_miss["reason"]
    assert_equal "Cache missed: 6k tokens read again in full, after the model changed.", helper.cache_miss_line(@conversation.latest_reply)
  end

  test "after a summary, the miss says how far the prompt shrank and counts only what this reply read in full" do
    reply(read: 250_000, write: 2_000)
    @conversation.messages.create!(entry_key: "summary", entry_id: @entry += 1, role: "summary", content: "<summary>\nx\n</summary>")
    after = reply(input: 2, read: 22_600, write: 38_000, at: 2.minutes)

    assert_equal 38_002, after.cache_miss["tokens"], "not the 252k before less the 22.6k read back"
    assert_equal "Cache missed: earlier messages were summarised (252k → 61k); 38k new tokens read in full.", helper.cache_miss_line(after)
  end

  test "no miss is told where nothing was cached, or the prompt is too short for any cache" do
    reply(input: 20_000)
    assert_nil reply(input: 20_400, at: 1.minute).cache_miss

    reply(write: 3_000, at: 2.minutes)
    assert_nil reply(input: 3_400, at: 3.minutes).cache_miss
  end

  test "a reply recorded from the sidecar is dated when its request began and names its model" do
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/12/entries}).to_return(body: { entries: [
      { id: "1", entryId: 1, role: "assistant", content: "Hi", at: @start.to_i * 1000, model: "anthropic/claude-opus-5-5",
        usage: { input: 3, output: 10, cacheRead: 0, cacheWrite: 20_000, totalTokens: 20_013, cost: 0 } }
    ], cursor: 1, more: false }.to_json)
    @conversation.sync!

    message = @conversation.messages.sole
    assert_equal @start, message.created_at
    assert_equal "anthropic/claude-opus-5-5", message.usage["model"]
    assert_equal 20_003, message.prompt_tokens
  end

  test "where the thread ends: the context as a share of the model, the cache's share, and its minutes" do
    stub_request(:get, "#{SIDECAR}/v1/models").to_return(body: { models: [
      { id: @agent.model, name: "Model", thinkingLevels: %w[ medium ], images: true, contextWindow: 200_000, compactAt: 160_000 } ] }.to_json)
    reply(write: 60_000)
    reply(read: 60_000, write: 24_000, at: 1.minute)
    @conversation.update!(usage: { "input" => 10, "cacheRead" => 60_000, "cacheWrite" => 84_000, "output" => 600, "totalTokens" => 144_610 })

    travel_to @start + 2.minutes do
      html = usage_html
      assert_includes html.text, "42% · 84k of 200k tokens"
      assert_includes html.text, "Automatic, at 160k"
      assert_includes html.text, "42% served from cache"
      assert_equal "warm", html.at_css(".chat__cache")["data-level"]
      assert_includes html.at_css(".chat__cache").text, "Cache warm for 59 more minutes."
      assert_equal "300", html.at_css(".chat__cache")["data-cache-timer-warning-value"]
    end
    travel_to @start + 58.minutes do
      assert_equal "near", usage_html.at_css(".chat__cache")["data-level"]
      assert_includes usage_html.at_css(".chat__cache").text, "Cache lapses in 3 minutes. After that, your next message reads all 84k tokens again."
    end
    travel_to @start + 60.minutes + 30.seconds do
      assert_includes usage_html.at_css(".chat__cache").text, "Cache lapses in under a minute."
    end
    travel_to @start + 62.minutes do
      assert_equal "over", usage_html.at_css(".chat__cache")["data-level"]
      assert_includes usage_html.at_css(".chat__cache").text, "Cache lapsed: your next message reads all 84k tokens again."
    end
  end

  test "settings that change what the agent reads warn while its cache is warm, and not after" do
    reply(write: 60_000)

    travel_to(@start + 2.minutes) { assert_includes warning, "prompt cache is warm for about 58 more minutes" }
    travel_to(@start + 2.minutes) { assert_includes warning, "that reply reads all 60k tokens again" }
    travel_to(@start + 61.minutes) { assert_empty warning.strip }
  end

  private
    # One reply's call: what it read new, read back and wrote to the cache, `at` after the start.
    def reply(input: 3, read: 0, write: 0, at: 0, model: "anthropic/claude-opus-5-5")
      total = input + read + write + 10
      @conversation.messages.create!(entry_key: "r#{@entry += 1}", entry_id: @entry, role: "assistant", content: "Reply", created_at: @start + at,
        usage: { "input" => input, "cacheRead" => read, "cacheWrite" => write, "output" => 10, "totalTokens" => total, "model" => model })
    end

    def helper = ApplicationController.helpers

    def render_message(message) = ApplicationController.render(partial: "messages/message", locals: { message: message })

    def usage_html = Nokogiri::HTML.fragment(ApplicationController.render(partial: "conversations/status_line", locals: { conversation: @conversation }))

    def warning = ApplicationController.render(partial: "agents/cache_warning", locals: { agent: @agent })
end
