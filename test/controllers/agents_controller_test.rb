require "test_helper"
require_relative "../test_helpers/agent_test_helper"

class AgentsControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: test reads the person it signed in
  end
  teardown { remove_sidecar_settings }

  # What the sidecar's GET /v1/models answers: pi-ai's facts per model.
  def stub_catalogue(*models)
    stub_request(:get, "#{SIDECAR}/v1/models").with(headers: { "Authorization" => "Bearer #{SIDECAR_TOKEN}" })
      .to_return(body: { models: models }.to_json)
  end

  test "the settings offer the allowed models the sidecar can run, each with its own thinking levels" do
    stub_catalogue({ id: "local/stand-in", name: "Local stand-in (no AI)", thinkingLevels: %w[ off minimal low medium high ], images: false, contextWindow: 200_000 },
      { id: "openai-codex/gpt-6.1-sol", name: "GPT-6.1 Sol", thinkingLevels: %w[ minimal low medium high xhigh max ], images: true, contextWindow: 500_000 },
      { id: "openai-codex/gpt-6-luna", name: "GPT-6 Luna", thinkingLevels: %w[ off low ], images: true, contextWindow: 272_000 })
    get edit_agent_path(@agent)

    assert_select "select[name='agent[model]'] option", 2, "only allowed models the sidecar runs"
    assert_select "select[name='agent[model]'] option[value='openai-codex/gpt-6.1-sol']", "GPT-6.1 Sol (ChatGPT subscription)"
    sol = css_select("option[value='openai-codex/gpt-6.1-sol']").first
    assert_equal [ [ "Minimal", "minimal" ], [ "Low", "low" ], [ "Medium", "medium" ], [ "High", "high" ], [ "Extra high", "xhigh" ], [ "Maximum", "max" ] ],
      JSON.parse(sol["data-thinking-levels"])
    assert_select "select[name='agent[thinking_level]'] option", 5, "the current model's levels"
    assert_select "select[name='agent[thinking_level]'] option[selected][value=medium]"
    assert_select "[data-controller=thinking-levels] select[data-action='thinking-levels#offer']"
  end

  test "with the sidecar unreachable, every allowed model is offered with every level" do
    stub_request(:get, "#{SIDECAR}/v1/models").to_return(status: 503, body: { error: "not_ready" }.to_json)
    get edit_agent_path(@agent)

    assert_response :success
    assert_select "select[name='agent[model]'] option", Agent.models.size
    assert_select "select[name='agent[thinking_level]'] option", Agent::THINKING_LEVELS.size
  end

  test "saving a level the model supports keeps it" do
    patch agent_path(@agent), params: { agent: { model: "openai-codex/gpt-6.1-sol", thinking_level: "xhigh" } }
    assert_redirected_to agent_path(@agent)
    assert_equal "xhigh", @agent.reload.thinking_level
    assert_equal "xhigh", @agent.definition[:thinkingLevel]
  end

  test "abilities are switched on the settings, each with a plain sentence" do
    stub_request(:get, "#{SIDECAR}/v1/models").to_return(status: 503, body: { error: "not_ready" }.to_json)
    get edit_agent_path(@agent)
    assert_select "input[type=checkbox][name='agent[capabilities][]'][checked]", 3
    assert_select "label", text: /Helpers\s*Hands a self-contained piece of work/

    patch agent_path(@agent), params: { agent: { capabilities: [ "", "web_search" ] } }
    assert_redirected_to agent_path(@agent)
    assert_equal %w[ web_search ], @agent.reload.capabilities

    patch agent_path(@agent), params: { agent: { capabilities: [ "" ] } }
    assert_equal [], @agent.reload.capabilities
  end
end
