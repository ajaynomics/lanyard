require "test_helper"
require_relative "../test_helpers/agent_test_helper"

class BotsControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    @bot = User.find_by!(oidc_sub: "42").bots.sole # tenancy-ok: test reads the person it signed in
  end
  teardown { remove_sidecar_settings }

  # What the sidecar's GET /v1/models answers: pi-ai's facts per model.
  def stub_catalogue(*models)
    stub_request(:get, "#{SIDECAR}/v1/models").with(headers: { "Authorization" => "Bearer #{SIDECAR_TOKEN}" })
      .to_return(body: { models: models }.to_json)
  end

  test "the settings offer the allowed models the sidecar can run, each with its own thinking levels" do
    stub_catalogue({ id: "local/avery-local", name: "Local stand-in (no AI)", thinkingLevels: %w[ off minimal low medium high ], images: false, contextWindow: 200_000 },
      { id: "openai-codex/gpt-6.1-sol", name: "GPT-6.1 Sol", thinkingLevels: %w[ minimal low medium high xhigh max ], images: true, contextWindow: 500_000 },
      { id: "openai-codex/gpt-6-luna", name: "GPT-6 Luna", thinkingLevels: %w[ off low ], images: true, contextWindow: 272_000 })
    get edit_bot_path(@bot)

    assert_select "select[name='bot[model]'] option", 2, "only allowed models the sidecar runs"
    assert_select "select[name='bot[model]'] option[value='openai-codex/gpt-6.1-sol']", "GPT-6.1 Sol (ChatGPT subscription)"
    sol = css_select("option[value='openai-codex/gpt-6.1-sol']").first
    assert_equal [ [ "Minimal", "minimal" ], [ "Low", "low" ], [ "Medium", "medium" ], [ "High", "high" ], [ "Extra high", "xhigh" ], [ "Maximum", "max" ] ],
      JSON.parse(sol["data-thinking-levels"])
    assert_select "select[name='bot[thinking_level]'] option", 5, "the current model's levels"
    assert_select "select[name='bot[thinking_level]'] option[selected][value=medium]"
    assert_select "[data-controller=thinking-levels] select[data-action='thinking-levels#offer']"
  end

  test "with the sidecar unreachable, every allowed model is offered with every level" do
    stub_request(:get, "#{SIDECAR}/v1/models").to_return(status: 503, body: { error: "not_ready" }.to_json)
    get edit_bot_path(@bot)

    assert_response :success
    assert_select "select[name='bot[model]'] option", Bot.models.size
    assert_select "select[name='bot[thinking_level]'] option", Bot::THINKING_LEVELS.size
  end

  test "saving a level the model supports keeps it" do
    patch bot_path(@bot), params: { bot: { model: "openai-codex/gpt-6.1-sol", thinking_level: "xhigh" } }
    assert_redirected_to bot_path(@bot)
    assert_equal "xhigh", @bot.reload.thinking_level
    assert_equal "xhigh", @bot.definition[:thinkingLevel]
  end

  test "abilities are switched on the settings, each with a plain sentence" do
    stub_request(:get, "#{SIDECAR}/v1/models").to_return(status: 503, body: { error: "not_ready" }.to_json)
    get edit_bot_path(@bot)
    assert_select "input[type=checkbox][name='bot[capabilities][]'][checked]", 3
    assert_select "label", text: /Helpers\s*Hands a self-contained piece of work/

    patch bot_path(@bot), params: { bot: { capabilities: [ "", "web_search" ] } }
    assert_redirected_to bot_path(@bot)
    assert_equal %w[ web_search ], @bot.reload.capabilities

    patch bot_path(@bot), params: { bot: { capabilities: [ "" ] } }
    assert_equal [], @bot.reload.capabilities
  end
end
