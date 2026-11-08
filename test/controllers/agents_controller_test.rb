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

  test "a name makes a new agent from the starter and opens its thread" do
    get new_agent_path
    assert_select "form[action=?] input[name='agent[name]']", agents_path

    assert_difference -> { @agent.user.agents.count } do
      post agents_path, params: { agent: { name: "  Garden   planner " } }
    end

    agent = @agent.user.agents.order(:id).last
    assert_redirected_to conversation_path(agent.conversation)
    assert_response :see_other
    assert_equal "Garden planner", agent.name
    assert_equal @agent.instructions, agent.instructions
    assert_equal @agent.tool_names, agent.tool_names
    assert_nil agent.conversation.durable_id
  end

  test "New agent says which model it will use, and whose" do
    stub_catalogue({ id: "anthropic/claude-sonnet-5-5", name: "Claude Sonnet 5.5", thinkingLevels: %w[ low medium high ] })
    @agent.update!(model: "anthropic/claude-sonnet-5-5")
    get new_agent_path
    assert_select ".field__hint", text: /Uses Claude Sonnet 5\.5 \(Claude subscription\), like Assistant\./
  end

  test "a purpose, if given, starts the new agent's instructions after the starter's" do
    post agents_path, params: { agent: { name: "Travel", purpose: "Plans our trips.\n" } }

    agent = @agent.user.agents.order(:id).last
    assert_equal "#{@agent.instructions}\n\n## Your purpose\n\nPlans our trips.", agent.instructions
  end

  test "with email, the settings show the agent's address and the person can change it" do
    with_setting(:mail, :domain, "agents.example") do
      with_setting(:mail, :smtp_address, "smtp.agents.example") do
        get agent_path(@agent)
        assert_select "input#agent_email_name[value=assistant]"
        assert_select "#email_domain", "@agents.example"
        get agent_channels_path(@agent)
        assert_select ".ui-row__value", text: "assistant@agents.example"

        patch agent_path(@agent), params: { agent: { email_name: "helper" } }
        assert_redirected_to agent_path(@agent)
        assert_equal "helper@agents.example", @agent.reload.email_address
        patch agent_path(@agent), params: { agent: { email_name: "Not An Address" } }
        assert_response :unprocessable_entity
        assert_select "input#agent_email_name[aria-invalid=true]"
        assert_select "p.field__error#agent_email_name_error", /Email name may have only lowercase letters/
      end
    end
  end

  test "a blank name is refused at the field, keeping what was typed" do
    assert_no_difference -> { Agent.count } do # tenancy-ok: counts every agent to prove none was made
      post agents_path, params: { agent: { name: " ", purpose: "Plans trips." } }
    end

    assert_response :unprocessable_entity
    assert_select "input#agent_name[aria-invalid=true][aria-describedby=agent_name_error]"
    assert_select "p.field__error#agent_name_error", "Name can't be blank"
    assert_select "textarea#agent_purpose", "Plans trips."
  end

  test "a new agent is its maker's alone" do
    post agents_path, params: { agent: { name: "Private" } }
    agent = @agent.user.agents.find_by!(name: "Private")

    sign_in_via_ajent(subject: "member", email: "member@example.com")
    get agent_path(agent)
    assert_response :not_found
    get conversation_path(agent.conversation)
    assert_response :not_found
    get conversations_path
    assert_select "a", text: "Private", count: 0
  end

  test "the settings offer the allowed models the sidecar can run, each with its own thinking levels" do
    stub_catalogue({ id: "local/stand-in", name: "Local stand-in (no AI)", thinkingLevels: %w[ off minimal low medium high ], images: false, contextWindow: 200_000 },
      { id: "openai-codex/gpt-6.1-sol", name: "GPT-6.1 Sol", thinkingLevels: %w[ minimal low medium high xhigh max ], images: true, contextWindow: 500_000 },
      { id: "openai-codex/gpt-6-luna", name: "GPT-6 Luna", thinkingLevels: %w[ off low ], images: true, contextWindow: 272_000 })
    get agent_path(@agent)

    assert_select "select[name='agent[model]'] option", 2, "only allowed models the sidecar runs"
    assert_select "select[name='agent[model]'] option[value='openai-codex/gpt-6.1-sol']", "GPT-6.1 Sol · Subscription"
    assert_select "form[data-controller~=autosave][data-action='change->autosave#save']"
    sol = css_select("option[value='openai-codex/gpt-6.1-sol']").first
    assert_equal [ [ "Minimal", "minimal" ], [ "Low", "low" ], [ "Medium", "medium" ], [ "High", "high" ], [ "Extra high", "xhigh" ], [ "Maximum", "max" ] ],
      JSON.parse(sol["data-thinking-levels"])
    assert_select "select[name='agent[thinking_level]'] option", 5, "the current model's levels"
    assert_select "select[name='agent[thinking_level]'] option[selected][value=medium]"
    assert_select "[data-controller~=thinking-levels] select[data-action='thinking-levels#offer']"
  end

  test "with the sidecar unreachable, every allowed model is offered with every level" do
    stub_request(:get, "#{SIDECAR}/v1/models").to_return(status: 503, body: { error: "not_ready" }.to_json)
    get agent_path(@agent)

    assert_response :success
    assert_select "select[name='agent[model]'] option", Agent.models.size
    assert_select "select[name='agent[model]'] option[value='anthropic/claude-sonnet-5-5']", "Claude Sonnet 5.5 · Subscription", "named in words, not by its route"
    assert_select "select[name='agent[thinking_level]'] option", Agent::THINKING_LEVELS.size
  end

  test "saving a level the model supports keeps it" do
    patch agent_path(@agent), params: { agent: { model: "openai-codex/gpt-6.1-sol", thinking_level: "xhigh" } }
    assert_redirected_to agent_path(@agent)
    assert_equal "xhigh", @agent.reload.thinking_level
    assert_equal "xhigh", @agent.conversation.definition[:thinkingLevel]
  end

  test "abilities are switched in the agent's Tools, each with a plain sentence" do
    get agent_tools_path(@agent)
    assert_select "input[type=checkbox][role=switch][name=on][checked]", 3 + @agent.tool_names.size + Tool::Catalog::CANVAS.size
    assert_select "label", text: /Helpers\s*Hands a self-contained piece of work/

    %w[ codemode subagents ].each { patch agent_tool_path(@agent, it), params: { on: "0" } }
    assert_redirected_to agent_tools_path(@agent)
    assert_equal %w[ web_search ], @agent.reload.capabilities

    patch agent_tool_path(@agent, "web_search"), params: { on: "0" }
    assert_equal [], @agent.reload.capabilities
    patch agent_tool_path(@agent, "web_search"), params: { on: "1" }
    assert_equal %w[ web_search ], @agent.reload.capabilities
    patch agent_tool_path(@agent, "change_yourself"), params: { on: "0" }
    assert_response :not_found
  end

  test "/model reads loosely: one match switches, several are listed with who pays, none lists what there is" do
    stub_catalogue({ id: "anthropic/claude-haiku-5-5", name: "Claude Haiku 5.5", thinkingLevels: %w[ low medium ] },
      { id: "anthropic-api/claude-haiku-5-5", name: "Claude Haiku 5.5", thinkingLevels: %w[ low medium ] },
      { id: "openai-codex/gpt-6.1-sol", name: "GPT-6.1 Sol", thinkingLevels: %w[ low medium ] })
    conversation = create_conversation(@agent)
    back = { "Referer" => conversation_url(conversation) }
    models = %w[ anthropic/claude-haiku-5-5 anthropic-api/claude-haiku-5-5 openai-codex/gpt-6.1-sol ]

    with_setting(:pi_durable, :models, models) do
      patch agent_path(@agent), params: { command: "model", agent: { model: "haiku" } }, headers: back
      assert_redirected_to conversation_url(conversation)
      assert_equal "“haiku” could be Claude Haiku 5.5 on the Claude subscription (anthropic/claude-haiku-5-5) or " \
        "Claude Haiku 5.5 on the Anthropic API key (anthropic-api/claude-haiku-5-5). Type more of the one you want.", flash[:alert]
      assert_not_equal "anthropic/claude-haiku-5-5", @agent.reload.model

      patch agent_path(@agent), params: { command: "model", agent: { model: "API/claude-haiku" } }, headers: back
      assert_equal "anthropic-api/claude-haiku-5-5", @agent.reload.model
      assert_equal "Saved. Assistant uses Claude Haiku 5.5 (Anthropic API key) from the next message.", flash[:notice]

      patch agent_path(@agent), params: { command: "model", agent: { model: "Sol" } }, headers: back
      assert_equal "openai-codex/gpt-6.1-sol", @agent.reload.model, "by its name, whatever the case"

      patch agent_path(@agent), params: { command: "model", agent: { model: "cla" } }, headers: back
      assert_match(/\A“cla” could be Claude Haiku/, flash[:alert])

      patch agent_path(@agent), params: { command: "model", agent: { model: "gemini" } }, headers: back
      assert_redirected_to conversation_url(conversation)
      assert_equal "No model matches “gemini”. You can choose Claude Haiku 5.5 on the Claude subscription (anthropic/claude-haiku-5-5), " \
        "Claude Haiku 5.5 on the Anthropic API key (anthropic-api/claude-haiku-5-5), or GPT-6.1 Sol on the ChatGPT subscription (openai-codex/gpt-6.1-sol).", flash[:alert]
      assert_equal "openai-codex/gpt-6.1-sol", @agent.reload.model
    end
  end

  test "/model that matches one model but cannot save says why, not that nothing matched" do
    stub_catalogue({ id: "openai-codex/gpt-6.1-sol", name: "GPT-6.1 Sol", thinkingLevels: %w[ low medium ] })
    @agent.update_column(:time_zone, "Atlantis")

    with_setting(:pi_durable, :models, [ @agent.model, "openai-codex/gpt-6.1-sol" ]) do
      patch agent_path(@agent), params: { command: "model", agent: { model: "Sol" } }, headers: { "Referer" => agent_url(@agent) }
    end
    assert_equal "Time zone is not included in the list", flash[:alert]
    assert_not_equal "openai-codex/gpt-6.1-sol", @agent.reload.model
  end
end
