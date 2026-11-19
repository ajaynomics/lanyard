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

  # What the sidecar's GET /v1/models answers: pi-ai's facts per model, and the
  # subscriptions signed in now.
  def stub_catalogue(*models, signed_in: %w[ openai-codex ])
    stub_request(:get, "#{SIDECAR}/v1/models").with(headers: { "Authorization" => "Bearer #{SIDECAR_TOKEN}" })
      .to_return(body: { models: models, signedIn: signed_in }.to_json)
  end

  SOL = { id: "openai-codex/gpt-6.1-sol", name: "GPT-6.1 Sol", thinkingLevels: %w[ low medium high ] }.freeze
  SONNET = { id: "anthropic/claude-sonnet-5-5", name: "Claude Sonnet 5.5", thinkingLevels: %w[ low medium high ] }.freeze

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
    assert_equal @agent.instructions.sub("You are Assistant,", "You are Garden planner,"), agent.instructions
    assert_equal @agent.tool_names, agent.tool_names
    assert_nil agent.conversation.durable_id
  end

  test "New agent shows the address the name would get, numbered past one taken, and says neither can change" do
    with_setting(:mail, :domain, "agents.example") do
      with_setting(:mail, :smtp_address, "smtp.agents.example") do
        get new_agent_path
        assert_select "turbo-frame#agent_address #agent_address_hint", text: /Its name and address can't be changed later/

        get agents_address_path(name: "  Garden   planner ")
        assert_select "turbo-frame#agent_address strong", "garden-planner@agents.example"
        assert_select "#agent_address_hint", text: /Its name and address can't be changed later/

        get agents_address_path(name: "Assistant")
        assert_select "turbo-frame#agent_address strong", "assistant-2@agents.example"

        post agents_path, params: { agent: { name: "Garden planner" } }
        assert_equal "garden-planner@agents.example", @agent.user.agents.order(:id).last.email_address
      end
    end

    get agents_address_path(name: "Garden planner")
    assert_select "turbo-frame#agent_address strong", count: 0
  end

  test "addresses are kept from Cloudflare's hiding, on the page and in a frame fetched after it" do
    with_setting(:mail, :domain, "agents.example") do
      with_setting(:mail, :smtp_address, "smtp.agents.example") do
        get agent_path(@agent)
        assert_email_off "#{@agent.email_name}@agents.example"

        get agents_address_path(name: "Garden planner"), headers: { "Turbo-Frame" => "agent_address" }
        assert_email_off "garden-planner@agents.example"
      end
    end
  end

  test "a chosen address is kept as typed, lowercased; a taken or malformed one is refused with the form kept" do
    with_setting(:mail, :domain, "agents.example") do
      with_setting(:mail, :smtp_address, "smtp.agents.example") do
        post agents_path, params: { agent: { name: "Jordan Reyes", email_name: " Jordan@ " } }
        assert_equal "jordan@agents.example", @agent.user.agents.order(:id).last.email_address

        assert_no_difference -> { @agent.user.agents.count } do
          post agents_path, params: { agent: { name: "Jordan Two", email_name: "jordan" } }
          assert_response :unprocessable_entity
          assert_select "input[name='agent[email_name]'][value=jordan]"

          post agents_path, params: { agent: { name: "Jordan Three", email_name: "jordan reyes" } }
          assert_response :unprocessable_entity
        end

        get agents_address_path(name: "Jordan Two", email_name: "jordan")
        assert_select "#agent_address_hint .field__error", "That address is another agent's."
        get agents_address_path(name: "Jordan Two", email_name: "Me nu")
        assert_select "#agent_address_hint .field__error", /only lowercase letters/
      end
    end
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
    assert_equal "#{@agent.instructions.sub("You are Assistant,", "You are Travel,")}\n\n## Your purpose\n\nPlans our trips.", agent.instructions
  end

  test "a title is given at New agent, shown under the name in both lists and in settings, changed in settings, and told to the agent apart from its name" do
    get new_agent_path
    assert_select "input[name='agent[title]']"
    post agents_path, params: { agent: { name: "Avery Reyes", title: "  Chief of   Staff " } }
    avery = @agent.user.agents.find_by!(name: "Avery Reyes")
    assert_equal "Chief of Staff", avery.title

    get conversations_path
    assert_select "#conversations .conversation-row__name", text: "Avery Reyes"
    assert_select "#conversations .conversation-row__name + .conversation-row__time + .conversation-row__title", text: "Chief of Staff"
    get conversation_path(avery.conversation)
    assert_select ".chat-sidebar .conversation-row__name", text: "Avery Reyes"
    assert_select ".chat-sidebar .conversation-row__name + .conversation-row__time + .conversation-row__title", text: "Chief of Staff"
    get agent_path(avery)
    assert_select ".settings__heading .settings__title", text: "Chief of Staff"

    assert_match(/\AYour name is Avery Reyes\. Neither can be changed\.\n\nYour title is Chief of Staff\.\n\n/, avery.conversation.definition[:instructions])
    patch agent_path(avery), params: { agent: { title: "x" * 61 } }
    assert_equal "Chief of Staff", avery.reload.title
    patch agent_path(avery), params: { agent: { title: " " } }
    assert_nil avery.reload.title
    assert_match(/\AYour name is Avery Reyes\. Neither can be changed\.\n\n(?!Your title)/, avery.conversation.reload.definition[:instructions])
    get conversations_path
    assert_select "#conversations .conversation-row__name", text: "Avery Reyes"
  end

  test "with email, the settings show the agent's name and address as fixed, and neither can be changed" do
    with_setting(:mail, :domain, "agents.example") do
      with_setting(:mail, :smtp_address, "smtp.agents.example") do
        get agent_path(@agent)
        assert_select "#agent_identity .ui-row__value", text: "Assistant"
        assert_select "#agent_identity .ui-row__value", text: "assistant@agents.example"
        assert_select "#agent_identity", text: /can't be changed/
        assert_select "input[name='agent[name]'], input[name='agent[email_name]']", count: 0

        patch agent_path(@agent), params: { agent: { name: "Helper", email_name: "helper", time_zone: "UTC" } }
        assert_equal [ "Assistant", "assistant@agents.example", "UTC" ], @agent.reload.then { [ it.name, it.email_address, it.time_zone ] }
      end
    end
  end

  test "deleting an agent needs its name typed, and warns what goes with it" do
    @agent.create_computer!(provider: "sprites", state: "on")
    with_setting(:mail, :domain, "agents.example") do
      with_setting(:mail, :smtp_address, "smtp.agents.example") do
        get agent_path(@agent)
        assert_select "#delete_agent", text: /assistant@agents\.example, stops working/
        assert_select "#delete_agent", text: /Its computer and everything on it are deleted/
        assert_select "#delete_agent label", "Type Assistant to confirm"
      end
    end

    assert_no_difference -> { Agent.count } do # tenancy-ok: counting what was deleted
      delete agent_path(@agent), params: { confirm_name: "assistant" }
    end
    assert_response :unprocessable_entity
    assert_select "#confirm_name_error", "Type Assistant exactly to delete it."

    theirs = create_user(name: "Mallory").agents.sole
    delete agent_path(theirs), params: { confirm_name: theirs.name }
    assert_response :not_found

    delete agent_path(@agent), params: { confirm_name: " Assistant " }
    assert_redirected_to root_path
    assert_not Agent.exists?(@agent.id) # tenancy-ok: proving it is gone
    assert Agent.exists?(theirs.id) # tenancy-ok: and theirs is not
  end

  test "a blank name is refused at the field, keeping what was typed" do
    assert_no_difference -> { Agent.count } do # tenancy-ok: counts every agent to prove none was made
      post agents_path, params: { agent: { name: " ", purpose: "Plans trips." } }
    end

    assert_response :unprocessable_entity
    assert_select "input#agent_name[aria-invalid=true][aria-describedby~=agent_name_error]"
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

  test "an agent may choose its own Claude account where the install has several, and only one of those" do
    stub_request(:get, "#{SIDECAR}/v1/models").to_return(status: 503, body: { error: "not_ready" }.to_json)
    get agent_path(@agent)
    assert_select "select[name='agent[claude_route]']", count: 0

    Rails.application.config.x.pi_durable = Rails.application.config.x.pi_durable.merge(claude_routes: [ "main", "spare" ])
    get agent_path(@agent)
    assert_equal [ "", "main", "spare" ], css_select("select[name='agent[claude_route]'] option").map { it["value"].to_s }
    assert_select "select[name='agent[claude_route]'] option[value='']", "The install's order"
    assert_no_match %r{/srv/lending}, response.body
    assert_select "#agent_claude_route_dropped", count: 0

    patch agent_path(@agent), params: { agent: { claude_route: "spare" } }
    assert_equal "spare", @agent.reload.claude_route
    patch agent_path(@agent), params: { agent: { claude_route: "elsewhere" } }
    assert_equal "spare", @agent.reload.claude_route
    patch agent_path(@agent), params: { agent: { claude_route: "" } }
    assert_nil @agent.reload.claude_route

    @agent.update_columns(claude_route: "retired")
    get agent_path(@agent)
    assert_select "select[name='agent[claude_route]'] option[selected][value=retired]"
    assert_select "#agent_claude_route_dropped", /retired is no longer one of this server's Claude accounts/
  end

  test "with the sidecar unreachable, every allowed model is offered with every level, but ChatGPT's, which can't be known signed in" do
    stub_request(:get, "#{SIDECAR}/v1/models").to_return(status: 503, body: { error: "not_ready" }.to_json)
    get agent_path(@agent)

    assert_response :success
    assert_select "select[name='agent[model]'] option", Agent.models.grep_v(%r{\Aopenai-(codex|chatgpt)/}).size
    assert_select "select[name='agent[model]'] option[value^='openai-codex/']", 0
    assert_select "select[name='agent[model]'] option[value^='openai-chatgpt/']", 0
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

  test "ChatGPT's models are offered only once its subscription is signed in, in the menus and to /model" do
    stub_catalogue(SONNET, SOL, signed_in: [])
    conversation = create_conversation(@agent)
    with_setting(:pi_durable, :models, [ SONNET[:id], SOL[:id] ]) do
      get agent_path(@agent)
      assert_select "select[name='agent[model]'] option[value='#{SONNET[:id]}']"
      assert_select "select[name='agent[model]'] option[value='#{SOL[:id]}']", 0
      get conversation_path(conversation)
      assert_select "#command_menu li[data-command=model][data-name='#{SONNET[:id]}']"
      assert_select "#command_menu li[data-command=model][data-name='#{SOL[:id]}']", 0

      patch agent_path(@agent), params: { command: "model", agent: { model: "sol" } }, headers: { "Referer" => conversation_url(conversation) }
      assert_equal "No model matches “sol”. You can choose Claude Sonnet 5.5 on the Claude subscription (#{SONNET[:id]}).", flash[:alert]
      assert_not_equal SOL[:id], @agent.reload.model

      stub_catalogue(SONNET, SOL, signed_in: %w[ anthropic ])
      get agent_path(@agent)
      assert_select "select[name='agent[model]'] option[value='#{SOL[:id]}']", 0, "Claude's sign-in is not ChatGPT's"

      stub_catalogue(SONNET, SOL)
      get agent_path(@agent)
      assert_select "select[name='agent[model]'] option[value='#{SOL[:id]}']", "GPT-6.1 Sol · Subscription"
      patch agent_path(@agent), params: { command: "model", agent: { model: "sol" } }, headers: { "Referer" => conversation_url(conversation) }
      assert_equal SOL[:id], @agent.reload.model
    end
  end

  test "a borrowed ChatGPT sign-in's models are offered only while the loan works, as the subscription's" do
    borrowed = { id: "openai-chatgpt/gpt-6.1-sol", name: "GPT-6.1 Sol", thinkingLevels: %w[ low medium high ] }
    stub_catalogue(SONNET, borrowed, signed_in: [])
    conversation = create_conversation(@agent)
    with_setting(:pi_durable, :models, [ SONNET[:id], borrowed[:id] ]) do
      get agent_path(@agent)
      assert_select "select[name='agent[model]'] option[value='#{borrowed[:id]}']", 0, "the lender is down or signed out"
      get conversation_path(conversation)
      assert_select "#command_menu li[data-command=model][data-name='#{borrowed[:id]}']", 0

      stub_catalogue(SONNET, borrowed, signed_in: %w[ openai-codex ])
      get agent_path(@agent)
      assert_select "select[name='agent[model]'] option[value='#{borrowed[:id]}']", 0, "the Codex sign-in is not the borrowed one"

      stub_catalogue(SONNET, borrowed, signed_in: %w[ openai-chatgpt ])
      get agent_path(@agent)
      assert_select "select[name='agent[model]'] option[value='#{borrowed[:id]}']", "GPT-6.1 Sol · Subscription"
      patch agent_path(@agent), params: { command: "model", agent: { model: "sol" } }, headers: { "Referer" => conversation_url(conversation) }
      assert_equal "Saved. #{@agent.name} uses GPT-6.1 Sol (ChatGPT subscription) from the next message.", flash[:notice]
      assert_equal borrowed[:id], @agent.reload.model
    end
  end

  test "an agent already on a ChatGPT model keeps it while nobody is signed in, and saving its settings doesn't change it" do
    stub_catalogue(SONNET, SOL, signed_in: [])
    @agent.update!(model: SOL[:id])
    with_setting(:pi_durable, :models, [ SONNET[:id], SOL[:id] ]) do
      get agent_path(@agent)
      assert_select "select[name='agent[model]'] option[selected][value='#{SOL[:id]}']", "GPT-6.1 Sol · Subscription"
      get conversation_path(create_conversation(@agent))
      assert_select "#command_menu li[data-command=model][data-name='#{SOL[:id]}']", 1, "its own model is still named"

      patch agent_path(@agent), params: { agent: { model: SOL[:id], title: "Travel" } }
      assert_equal [ SOL[:id], "Travel" ], @agent.reload.slice(:model, :title).values
    end
  end

  test "an agent on a model taken off the allow-list keeps it and runs on it, and it can't be chosen anew" do
    gone = { id: "openai-codex/gpt-6-sol", name: "GPT-6 Sol", thinkingLevels: %w[ low medium ] }
    stub_catalogue(SONNET, SOL, gone)
    @agent.update!(model: SOL[:id])
    @agent.update_column(:model, gone[:id])

    with_setting(:pi_durable, :models, [ SONNET[:id], SOL[:id] ]) do
      get agent_path(@agent)
      assert_select "select[name='agent[model]'] option[selected][value='#{gone[:id]}']", "GPT-6 Sol · Subscription", "shown as what it has"
      assert_select "select[name='agent[thinking_level]'] option", 2, "with its own levels"

      patch agent_path(@agent), params: { agent: { model: gone[:id], title: "Travel" } }
      assert_equal [ gone[:id], "Travel" ], @agent.reload.slice(:model, :title).values
      assert_equal gone[:id], create_conversation(@agent).definition[:model], "the sidecar is still asked for it"

      patch agent_path(@agent), params: { agent: { model: SOL[:id] } }
      assert_equal SOL[:id], @agent.reload.model
      patch agent_path(@agent), params: { agent: { model: gone[:id] } }
      assert_equal SOL[:id], @agent.reload.model, "once changed, it can't be chosen again"
      get agent_path(@agent)
      assert_select "select[name='agent[model]'] option[value='#{gone[:id]}']", 0
    end
  end

  private
    def assert_email_off(address)
      shown = response.body.index(address)
      assert shown, "#{address} is on the page"
      assert_operator response.body.rindex("<!--email_off-->", shown) || -1, :>, response.body.rindex("<!--/email_off-->", shown) || -1
      assert response.body.index("<!--/email_off-->", shown), "the region is closed after #{address}"
    end
end
