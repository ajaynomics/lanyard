require "test_helper"

class ModelCatalogTest < ActiveSupport::TestCase
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
    config = Rails.application.config_for(:pi_durable, env: "production")
    %w[ claude-opus-5-5 claude-sonnet-5-5 claude-haiku-5-5 ].each do |model|
      assert_includes config[:models], "anthropic/#{model}"
      assert_includes config[:models], "anthropic-api/#{model}"
    end
    assert_equal "anthropic/claude-opus-5-5", config[:default_model]
  end
end
