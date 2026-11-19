require "test_helper"
require_relative "../test_helpers/agent_test_helper"

class ModelCatalogTest < ActiveSupport::TestCase
  include AgentTestHelper

  def label(id) = ModelCatalog::Choice.new(id: id, name: "Claude Sonnet 5.5", thinking_levels: %w[ medium ]).label

  test "a Claude model says whether the subscription or the API key pays for it" do
    assert_equal "Claude Sonnet 5.5 (Claude subscription)", label("anthropic/claude-sonnet-5-5")
    assert_equal "Claude Sonnet 5.5 (Anthropic API key)", label("anthropic-api/claude-sonnet-5-5")
  end

  test "settings name a model in words, with who pays as quiet words beside it, never its route" do
    assert_equal "Claude Haiku 5.5", ModelCatalog.plain_name("anthropic/claude-haiku-5-5")
    assert_equal "GPT 6.1 Sol", ModelCatalog.plain_name("openai-codex/gpt-6.1-sol")
    choice = ModelCatalog::Choice.new(id: "anthropic-api/claude-sonnet-5-5", name: "Claude Sonnet 5.5", thinking_levels: %w[ medium ])
    assert_equal "API key", choice.source
    assert_equal "Claude Sonnet 5.5 · API key", choice.option_label
    assert_equal "Claude Sonnet 5.5 · Subscription", ModelCatalog::Choice.new(id: "anthropic/claude-sonnet-5-5", name: "Claude Sonnet 5.5", thinking_levels: []).option_label
  end

  test "both ways to Claude are on the allow-list, and the default is unchanged" do
    %w[ production development ].each do |env|
      config = Rails.application.config_for(:pi_durable, env: env)
      %w[ anthropic anthropic-api ].each do |route|
        assert_equal %w[ claude-fable-5-2 claude-opus-5-5 claude-sonnet-5-5 claude-haiku-5-5 ],
          config[:models].grep(%r{\A#{route}/}).map { it.delete_prefix("#{route}/") }, "#{route}, #{env}"
      end
    end
    assert_equal "anthropic/claude-opus-5-5", Rails.application.config_for(:pi_durable, env: "production")[:default_model]
  end

  # GPT-6.2 Sol and Astra replace GPT-6.1 Sol and GPT-6 Astra on both
  # subscription routes (#272). The API key's route offers no GPT until a key
  # confirms 6.2 there; an agent already on openai/gpt-6.1-sol keeps it.
  test "ChatGPT's offer is GPT-6.2 Sol, GPT-6.2 Astra, GPT-6.1 Terra and GPT-6 Luna, and the API key offers none" do
    %w[ production development ].each do |env|
      config = Rails.application.config_for(:pi_durable, env: env)
      assert_equal %w[ gpt-6.2-sol gpt-6.2-astra gpt-6.1-terra gpt-6-luna ],
        config[:models].grep(%r{\Aopenai-codex/}).map { it.delete_prefix("openai-codex/") }, env
      assert_equal %w[ gpt-6.2-sol gpt-6.2-astra gpt-6.1-terra gpt-6-luna ],
        config[:models].grep(%r{\Aopenai-chatgpt/}).map { it.delete_prefix("openai-chatgpt/") }, "borrowed, #{env}"
      assert_empty config[:models].grep(%r{\Aopenai/}), "API key, #{env}"
    end
  end

  test "a borrowed ChatGPT sign-in's model says the subscription pays, so its thread says Included in plan" do
    choice = ModelCatalog::Choice.new(id: "openai-chatgpt/gpt-6.1-sol", name: "GPT-6.1 Sol", thinking_levels: %w[ medium ])
    assert_equal "GPT-6.1 Sol (ChatGPT subscription)", choice.label
    assert_equal "GPT-6.1 Sol · Subscription", choice.option_label
    assert_equal "GPT-6.1 Sol · API key", ModelCatalog::Choice.new(id: "openai/gpt-6.1-sol", name: "GPT-6.1 Sol", thinking_levels: []).option_label
  end

  test "signing in or out of a subscription forgets the cached catalogue, so the menus change at once" do
    install_sidecar_settings
    saved, Rails.cache = Rails.cache, ActiveSupport::Cache::MemoryStore.new
    base = "#{AgentTestHelper::SIDECAR}/v1/subscriptions/openai-codex"
    stub_request(:post, "#{base}/finish").to_return(body: { connected: true, version: 2 }.to_json)
    stub_request(:post, "#{base}/disconnect").to_return(status: 503, body: { error: "not_ready" }.to_json)
    subscription = Subscription.new("openai-codex", {})

    Rails.cache.write(ModelCatalog::CACHE_KEY, { "models" => {}, "signed_in" => [] })
    subscription.finish(version: 1, id: "p", code: "c")
    assert_nil Rails.cache.read(ModelCatalog::CACHE_KEY)

    Rails.cache.write(ModelCatalog::CACHE_KEY, { "models" => {}, "signed_in" => [ "openai-codex" ] })
    assert_raises(DurableAssistants::PiDurable::Client::Error) { subscription.disconnect(2) }
    assert_nil Rails.cache.read(ModelCatalog::CACHE_KEY), "even when the sidecar's answer is lost"
  ensure
    Rails.cache = saved
    remove_sidecar_settings
  end
end
